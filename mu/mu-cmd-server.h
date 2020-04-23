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

#ifndef __MU_CMD_SERVER_H__
#define __MU_CMD_SERVER_H__

#include <glib.h>

#include "mu-index.h"
#include "mu-query.h"
#include "mu-store.hh"

#include "utils/mu-command-parser.hh"

using namespace Mu;
using namespace Command;

G_BEGIN_DECLS

struct Context {
	Context(){}
	Context (MuConfig *opts);
	virtual ~Context();

        Context(const Context&) = delete;

        MuStore *store{};
        MuQuery *query{};
        bool do_quit{};

        CommandMap command_map;

	// The 'this' pointer is an implicit argument for the purposes of G_GNUC_PRINTF.
        virtual void print_expr (const char* frm, ...) G_GNUC_PRINTF(2, 3);
        /* Out-of-band messages that are not replies to a request. */
        virtual void print_expr_oob (const char* frm, ...) G_GNUC_PRINTF(2, 3);
        virtual MuError print_error (MuError errcode, const char* frm, ...) G_GNUC_PRINTF(3, 4);
        virtual unsigned print_sexps (MuMsgIter *iter, unsigned maxnum);
};

extern CommandMap make_command_map (Context& context);

extern void install_sig_handler (void);

G_END_DECLS

#endif /* __MU_CMD_SERVER_H__ */
