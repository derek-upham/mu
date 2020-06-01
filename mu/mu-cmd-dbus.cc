/* -*-mode: c++; tab-width: 8; indent-tabs-mode: t; c-basic-offset: 8 -*-*/
/*
** Copyright (C) 2011-2012 Dirk-Jan C. Binnema <djcb@djcbsoftware.nl>
**
** This program is free software; you can redistribute it and/or modify it
** under the terms of the GNU General Public License as published by the
** Free Software Foundation; either version 3, or (at your option) any
** later version.
**
** This program is distributed in the hope that it will be useful,
** but WITHOUT ANY WARRANTY; without even the implied warranty of
** MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
** GNU General Public License for more details.
**
** You should have received a copy of the GNU General Public License
** along with this program; if not, write to the Free Software Foundation,
** Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
**
*/

#include <cassert>
#include <ctype.h>
#include <string.h>
#include <unistd.h>

#include <glib-unix.h>
#include <glib/gprintf.h> /* for g_vasprintf */

#include "mu-cmd.h"
#include "mu-cmd-server.h"
#include "mu-runtime.h"

#include "utils/mu-str.h"

#include "mu-server-dbus-glue.h"

/* Managed by mu_cmd_dbus() when we run "dbus" command. */
static GMainLoop *dbus_loop;

/* Managed by on_bus_acquired when we connect to D-Bus. */
static GDBusObjectManagerServer *dbus_object_manager;

struct DBusContext
	:public Context
{
	DBusContext(Context& context, MuServer *response_server_, GDBusMethodInvocation *invocation_);
	virtual ~DBusContext();

	// The 'this' pointer is an implicit argument for the purposes of G_GNUC_PRINTF.
        void print_expr (const char* frm, ...) G_GNUC_PRINTF(2, 3);
	void print_expr_oob (const char* frm, ...) G_GNUC_PRINTF(2, 3);
        MuError print_error (MuError errcode, const char* frm, ...) G_GNUC_PRINTF(3, 4);
        unsigned print_sexps (MuMsgIter *iter, unsigned maxnum);

	GDBusMethodInvocation *invocation;

	void send_response();
	MuServer *response_server;
	GString *response_buffer;

	// There can be only one DatabaseContext, so ephemeral DBus
	// contexts need to point to that DatabaseContext.
	// DatabaseContext exposes 'store' and 'query' directly as
	// members, so we can't use simple forwarding accessors.
	// Instead, we clone the pointers (without taking ownership).
	//
	// We manage our own 'do_quit'.  It doesn't need to persist
	// across D-Bus calls.
	//
	// We construct our own 'command_map' fresh each time through,
	// to guarantee that its callbacks point to this object (so
	// they update the correct 'do_quit').
	Context &impl_;
};


DBusContext::DBusContext(Context &context, MuServer *response_server_, GDBusMethodInvocation *invocation_)
	:impl_(context)
{
	store = impl_.store;
	query = impl_.query;
	do_quit = false;
	command_map = make_command_map (*this);
	response_server = response_server_;
	invocation = invocation_;
	response_buffer = g_string_sized_new (512);
	assert (response_buffer != NULL);
}

DBusContext::~DBusContext()
{
	// Zero-out these so we don't attempt to free our copies.
	store = 0;
	query = 0;

	if (response_buffer) {
		g_string_free (response_buffer, TRUE);
	}
}

void
DBusContext::print_expr (const char *frm, ...)
{
	va_list ap;
	va_start (ap, frm);
	g_string_append_vprintf (response_buffer, frm, ap);
	va_end (ap);
}

void
DBusContext::print_expr_oob (const char *frm, ...)
{
	va_list ap;

	GString *oob_buffer = g_string_sized_new (512);
	va_start (ap, frm);
	g_string_append_vprintf (oob_buffer, frm, ap);
	va_end (ap);
	gchar *char_data = g_string_free (oob_buffer, FALSE);
	mu_server_emit_oobmessage (response_server, char_data);
	g_free(char_data);
}

MuError
DBusContext::print_error (MuError errcode, const char *frm, ...)
{
        char    *msg;
        va_list  ap;

        va_start (ap, frm);
        g_vasprintf (&msg, frm, ap);
        va_end (ap);

        char *str = mu_str_escape_c_literal (msg, TRUE);
	g_string_append_printf (response_buffer, "(:error %u :message %s)", errcode, str);

        g_free (str);
        g_free (msg);

        return errcode;
}

unsigned
DBusContext::print_sexps (MuMsgIter *iter, unsigned maxnum)
{
        unsigned u;
        u = 0;

        while (!mu_msg_iter_is_done (iter) && u < maxnum) {

                MuMsg *msg;
                msg = mu_msg_iter_get_msg_floating (iter);

                if (mu_msg_is_readable (msg)) {
                        char *sexp;
                        const MuMsgIterThreadInfo* ti;
                        ti   = mu_msg_iter_get_thread_info (iter);
                        sexp = mu_msg_to_sexp (msg,
                                               mu_msg_iter_get_docid (iter),
                                               ti, MU_MSG_OPTION_HEADERS_ONLY);
                        print_expr ("%s", sexp);
                        g_free (sexp);
                        ++u;
                }
                mu_msg_iter_next (iter);
        }
        return u;
}

void
DBusContext::send_response()
{
	gchar *char_data = g_string_free (response_buffer, FALSE);
	response_buffer = NULL;
	mu_server_complete_execute (response_server, invocation, char_data);
	g_free(char_data);
}

static gboolean
on_maildirmanager_execute (MuServer			*md_mgr,
			   GDBusMethodInvocation	*invocation,
			   gchar			*payload,
			   gpointer			 user_data)
{
	Context* context_ptr = reinterpret_cast<Context*>(user_data);

	DBusContext dbus_context{*context_ptr, md_mgr, invocation};

	try {
		const std::string line = std::string (payload);
		invoke (dbus_context.command_map, Sexp::parse(line));
	}
	catch (const Error& er) {
		dbus_context.print_error ((MuError) er.code(), "%s", er.what());
	}
	dbus_context.send_response();

	if (dbus_context.do_quit) {
		g_main_loop_quit (dbus_loop);
	}

	/* we have handled this request */
	return TRUE;
}

static void
setup_maildir_manager_signal_callbacks(MuServer *md_mgr, gpointer user_data)
{
	g_signal_connect (md_mgr, "handle-execute",
			  G_CALLBACK (on_maildirmanager_execute),
			  user_data);
}

static void
on_bus_acquired (GDBusConnection *connection,
                 const gchar *name,
                 gpointer user_data)
{
	// OBJECT_MANAGER_PATH has to be a prefix of
	// OBJECT_SKELETON_PATH.  We set up a distinct bus name for
	// each database/lock, so there's no point in changing these
	// for different instances.
	const char *OBJECT_MANAGER_PATH = "/mu";
	const char *OBJECT_SKELETON_PATH = "/mu/cache";

	MuObjectSkeleton *object = mu_object_skeleton_new (OBJECT_SKELETON_PATH);

	MuServer *md_mgr = mu_server_skeleton_new ();
	mu_object_skeleton_set_server (object, md_mgr);
	setup_maildir_manager_signal_callbacks(md_mgr, user_data);

	dbus_object_manager = g_dbus_object_manager_server_new (OBJECT_MANAGER_PATH);
	g_dbus_object_manager_server_export (dbus_object_manager,
					     G_DBUS_OBJECT_SKELETON (object));
	g_object_unref (object);

	g_dbus_object_manager_server_set_connection (dbus_object_manager,
						     connection);
}

/**
 * Construct a bus name for this MU server.  The server runs in the
 * session bus, so we don't need to worry about conflicts between
 * accounts.
 *
 * The optional "suffix" allows a user to run more than one MU D-Bus
 * server simultaneously.  The servers have to be on different
 * indexes, of course.  The suffix is restricted to alphanumeric
 * characters; those are guaranteed to be safe in registered names.
 *
 * The caller is responsible for freeing the return value with g_free().
 */
static gchar *
construct_bus_name (const gchar *suffix)
{
	const char *base = "nl.djcbsoftware.Mu.Maildir";

	if (suffix) {
		size_t len = strlen(suffix);
		for (size_t i=0; i<len; ++i) {
			if (! isalnum (suffix[i])) {
				throw Mu::Error (Error::Code::InvalidArgument, "non-alphanumeric character in bus name suffix");
			}
		}

		return g_strconcat (base, ".", suffix, NULL);
	}
	else
		return g_strdup (base);
}

static void
on_terminating_signal(gpointer *dummy)
{
	MuTerminate = true;
	g_main_loop_quit (dbus_loop);
}

// Pass the loop object as an explicit argument, to make this
// function's dependency on it clear.
static void
install_dbus_sig_handler (GMainLoop *main_loop)
{
	MuTerminate = false;

	int sigs[] = { SIGINT, SIGHUP, SIGTERM };
	for (size_t u = 0; u != G_N_ELEMENTS(sigs); ++u) {
		GSource	*source = g_unix_signal_source_new (sigs[u]);
		g_source_set_callback (source,
				       (GSourceFunc)on_terminating_signal,
				       NULL, NULL);
		g_source_attach (source, g_main_loop_get_context(dbus_loop));
		g_source_unref (source);
	}
}

MuError
mu_cmd_dbus (MuConfig *opts, GError **err) try
{
	gchar *bus_name = construct_bus_name (opts->dbus_suffix);

	// 'context' holds the complete operating context.  It has to
	// stick around for as long as the event loop runs.
	Context context(opts);

	guint id = g_bus_own_name (G_BUS_TYPE_SESSION,
				   bus_name,
				   G_BUS_NAME_OWNER_FLAGS_NONE,
				   on_bus_acquired,
				   NULL,
				   NULL,
				   &context,
				   NULL);

	dbus_loop = g_main_loop_new (NULL, FALSE);

	install_dbus_sig_handler(dbus_loop);

	g_main_loop_run (dbus_loop);
	g_main_loop_unref (dbus_loop);

	g_bus_unown_name (id);

	g_free (bus_name);

	return MU_OK;
} catch (const Mu::Error& er) {
	g_set_error(err, MU_ERROR_DOMAIN, MU_ERROR, "%s", er.what());
	return MU_ERROR;
}
