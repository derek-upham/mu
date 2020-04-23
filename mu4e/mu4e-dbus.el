;; mu4e-dbus.el -- part of mu4e, the mu mail user agent -*- lexical-binding: t -*-
;;
;; Copyright (C) 2011-2012 Dirk-Jan C. Binnema

;; Author: Dirk-Jan C. Binnema <djcb@djcbsoftware.nl>
;; Maintainer: Dirk-Jan C. Binnema <djcb@djcbsoftware.nl>

;; This file is not part of GNU Emacs.
;;
;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; The mu4e-proc code checks for a running server with every
;; mu4e~call-mu call.  That doesn't work with the mu4e-dbus code.
;; Something about the high-frequency dbus-list-names calls seems to
;; screw up deletion of messages in the *mu4e-headers* buffer.

;;; Code:

(require 'dbus)

(require 'mu4e-proc)
(require 'mu4e-utils)
(require 'mu4e-vars)

(defconst mu4e~dbus-message-bus :session
  "The D-Bus bus for communication with the MU server, normally `:session'.")

(defconst mu4e~dbus-registered-name "nl.djcbsoftware.Mu.Maildir"
  "The MU server registered name on the D-Bus message bus.")

(defconst mu4e~dbus-object-path "/mu/cache"
  "The MU server's D-Bus object path to the index owner.")

(defconst mu4e~dbus-interface "nl.djcbsoftware.Mu.Server"
  "The protocol that the MU index owner follows.")

(defconst mu4e~dbus-method "Execute"
  "The method to use for sending commands to the `mu4e~dbus-interface'.")

(defconst mu4e~dbus-oob-signal "OOBMessage"
  "The MU server's D-bus signal for out-of-band messages.")

(defvar mu4e~dbus-timeout 60000
  "Time to wait for a response from the Mu server.")

(defvar mu4e~dbus-start-wait-max-count 20
  "Number of times to check for the mu dbus (un)registration.")

(defvar mu4e~dbus-start-wait-time '(0 100)
  "Delay between mu dbus (un)registration checks.

This variable is a list of (SECONDS MILLISECONDS).")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; internal vars

(defvar mu4e~dbus-server-status nil
  "A symbol indicating the current status of the mu dbus server instance.

  - `spawned' means the current Emacs instance has spawned an instance.
  - `daemon' means that an instance exists outside of Emacs
  - nil means the current status is unknown.

")

(defvar mu4e~dbus-buf nil
  "Buffer (string) for data received from the backend.")
(defconst mu4e~dbus-name " *mu4e-dbus*"
  "Name of the server process, buffer.")
(defvar mu4e~dbus-process nil
  "The mu-dbus process.")

(defvar mu4e~dbus-oob-signal-registration-object nil
  "Registration object for receiving out-of-band signals from MU.")
(defvar mu4e~dbus-needs-event-bug-fix
  (or (< emacs-major-version 24)
      (and (= emacs-major-version 24)
           (< emacs-minor-version 4)))
  "Work around special-event-map bug in Emacs < 24.4.

In Emacs before v24.4, the set of active keymaps is determined at
the end of the previous command.  Any change to the keymap done
outside the normal command loop (like a special-event-map
binding) leaves Emacs looking at the old keymap.  Both major mode
changes and selected-buffer changes trigger this.

As a workaround, we can add a dummy event to the
`unread-command-event' queue, bound to `ignore'.  That forces
Emacs to recalculate the active keymap.

Emacs 24.4 has a fix for this bug.")

(when mu4e~dbus-needs-event-bug-fix
  (define-key global-map [mu4e~dbus-fake-event] 'ignore))

(defun mu4e~dbus-ensure-running-server ()
  "Determine the current status of the mu dbus server instance.

This updates mu4e~dbus-server-status as necessary.

Spawn a server if one is not yet running."
  (when (null mu4e~dbus-server-status)
    (if (mu4e~dbus-daemon-running-p)
        (setq mu4e~dbus-server-status 'daemon)
      (mu4e~dbus-start)
      (setq mu4e~dbus-server-status 'spawned))))

(defun mu4e~dbus-running-p  ()
  "Whether a mu dbus server instance is running."
  mu4e~dbus-server-status)

(defun mu4e~dbus-daemon-running-p  ()
  "Whether a mu dbus server instance is running as a daemon."
  (member mu4e~dbus-registered-name
          (dbus-list-names mu4e~dbus-message-bus)))

(defun mu4e~dbus-handler (response)
  "A handler for the 'mu dbus' output.
It parses the responses as a series of sexps and passes them for evaluation."
  (let ((all-sexps nil))
    (with-temp-buffer
      (insert response)
      (goto-char (point-min))
      (let ((sexp (ignore-errors (read (current-buffer)))))
        (while sexp
          (push sexp all-sexps)
          (setq sexp (ignore-errors (read (current-buffer)))))))
    (dolist (sexp (nreverse all-sexps))
      (mu4e~dbus-dispatch-on-sexp sexp)))
  (when (and mu4e~dbus-needs-event-bug-fix
             (not (eq (car unread-command-events) 'mu4e~dbus-fake-event)))
    (push 'mu4e~dbus-fake-event unread-command-events)))

;; This is just hand-copied from the corresponding code in
;; mu4e~proc-filter as necessary.
(defun mu4e~dbus-dispatch-on-sexp (sexp)
  "Filter string STR from PROC.
This processes the 'mu server' output. It accumulates the
strings into valid sexps by checking of the ';;eox' `end-of-sexp'
marker, and then evaluating them.

The server output is as follows:

   1. an error
      (:error 2 :message \"unknown command\")
      ;; eox
   => passed to `mu4e-error-func'.

   2a. a message sexp looks something like:
 \(
  :docid 1585
  :from ((\"Donald Duck\" . \"donald@example.com\"))
  :to ((\"Mickey Mouse\" . \"mickey@example.com\"))
  :subject \"Wicked stuff\"
  :date (20023 26572 0)
  :size 15165
  :references (\"200208121222.g7CCMdb80690@msg.id\")
  :in-reply-to \"200208121222.g7CCMdb80690@msg.id\"
  :message-id \"foobar32423847ef23@pluto.net\"
  :maildir: \"/archive\"
  :path \"/home/mickey/Maildir/inbox/cur/1312254065_3.32282.pluto,4cd5bd4e9:2,\"
  :priority high
  :flags (new unread)
  :attachments ((2 \"hello.jpg\" \"image/jpeg\") (3 \"laah.mp3\" \"audio/mp3\"))
  :body-txt \" <message body>\"
\)
;; eox
   => this will be passed to `mu4e-header-func'.

  2b. After the list of message sexps has been returned (see 2a.),
  we'll receive a sexp that looks like
  (:found <n>) with n the number of messages found. The <n> will be
  passed to `mu4e-found-func'.

  3. a view looks like:
  (:view <msg-sexp>)
  => the <msg-sexp> (see 2.) will be passed to `mu4e-view-func'.

  4. a database update looks like:
  (:update <msg-sexp> :move <nil-or-t>)

   => the <msg-sexp> (see 2.) will be passed to
   `mu4e-update-func', :move tells us whether this is a move to
   another maildir, or merely a flag change.

  5. a remove looks like:
  (:remove <docid>)
  => the docid will be passed to `mu4e-remove-func'

  6. a compose looks like:
  (:compose <reply|forward|edit|new> [:original<msg-sexp>] [:include <attach>])
  `mu4e-compose-func'."
  (mu4e-log 'from-server "%S" sexp)
  (cond
   ;; a header plist can be recognized by the existence of a :date field
   ((plist-get sexp :date)
    (funcall mu4e-header-func sexp))

   ;; the found sexp, we receive after getting all the headers
   ((plist-get sexp :found)
    (funcall mu4e-found-func (plist-get sexp :found)))

   ;; viewing a specific message
   ((plist-get sexp :view)
    (funcall mu4e-view-func (plist-get sexp :view)))

   ;; receive an erase message
   ((plist-get sexp :erase)
    (funcall mu4e-erase-func))

   ;; receive a :sent message
   ((plist-get sexp :sent)
    (funcall mu4e-sent-func
             (plist-get sexp :docid)
             (plist-get sexp :path)))

   ;; received a pong message
   ((plist-get sexp :pong)
    (funcall mu4e-pong-func sexp))

   ;; received a contacts message
   ;; note: we use 'member', to match (:contacts nil)
   ((plist-member sexp :contacts)
    (funcall mu4e-contacts-func
             (plist-get sexp :contacts)
             (plist-get sexp :tstamp)))

   ;; something got moved/flags changed
   ((plist-get sexp :update)
    (funcall mu4e-update-func
             (plist-get sexp :update)
             (plist-get sexp :move)
             (plist-get sexp :maybe-view)))

   ;; a message got removed
   ((plist-get sexp :remove)
    (funcall mu4e-remove-func (plist-get sexp :remove)))

   ;; start composing a new message
   ((plist-get sexp :compose)
    (funcall mu4e-compose-func
             (plist-get sexp :compose)
             (plist-get sexp :original)
             (plist-get sexp :include)))

   ;; do something with a temporary file
   ((plist-get sexp :temp)
    (funcall mu4e-temp-func
             (plist-get sexp :temp)   ;; name of the temp file
             (plist-get sexp :what)   ;; what to do with it
             ;; (pipe|emacs|open-with...)
             (plist-get sexp :docid)  ;; docid of the message
             (plist-get sexp :param)));; parameter for the action

   ;; get some info
   ((plist-get sexp :info)
    (funcall mu4e-info-func sexp))

   ;; receive an error
   ((plist-get sexp :error)
    (funcall mu4e-error-func
             (plist-get sexp :error)
             (plist-get sexp :message)))

   (t (mu4e-message "Unexpected data from server [%S]" sexp))))

(defun mu4e~dbus-call-mu (form)
  "Send as command to the mu server process."
  (mu4e~dbus-ensure-running-server)
  (unless mu4e~dbus-oob-signal-registration-object
    (setq mu4e~dbus-oob-signal-registration-object
          (dbus-register-signal :session
                                nil
                                mu4e~dbus-object-path
                                mu4e~dbus-interface
                                mu4e~dbus-oob-signal
                                'mu4e~dbus-handler)))
  
  (let ((cmd (format "%S" form)))
    (mu4e-log 'to-server "%s" cmd)
    (dbus-call-method-asynchronously
     mu4e~dbus-message-bus
     mu4e~dbus-registered-name
     mu4e~dbus-object-path
     mu4e~dbus-interface
     mu4e~dbus-method
     'mu4e~dbus-handler
     :timeout mu4e~dbus-timeout
     cmd)))

(defun mu4e~dbus-start ()
  "Start the mu D-Bus server process.

The mu process will be a child process of Emacs.  It will only
run for as long as this Emacs instance does."
  (unless (file-executable-p mu4e-mu-binary)
    (mu4e-error (format "`mu4e-mu-binary' (%S) not found" mu4e-mu-binary)))
  (let* ((process-connection-type nil) ;; use a pipe
         (args '("dbus"))
         (args (append args (when mu4e-mu-home
                              (list (concat "--muhome=" mu4e-mu-home))))))
    (setq mu4e~dbus-buf "")
    (setq mu4e~dbus-process (apply 'start-process
                                   mu4e~dbus-name mu4e~dbus-name
                                   mu4e-mu-binary args))
    (unless mu4e~dbus-process
      (mu4e-error "Failed to start the mu4e backend"))
    (set-process-query-on-exit-flag mu4e~dbus-process nil)
    (set-process-coding-system mu4e~dbus-process nil nil)
    ;; register a function for (:info ...) sexps
    (set-process-filter mu4e~dbus-process nil)
    (set-process-sentinel mu4e~dbus-process 'mu4e~dbus-sentinel)
    ;; It takes a little time for the "mu dbus" process to register
    ;; itself with the D-Bus server.
    (cl-loop for i from 1 upto mu4e~dbus-start-wait-max-count
             when (mu4e~dbus-daemon-running-p)
             return nil
             when (= i mu4e~dbus-start-wait-max-count)
             do (mu4e-error "mu4e backend did not register in time")
             do (apply 'sleep-for mu4e~dbus-start-wait-time))))

(defun mu4e~dbus-kill ()
  "Kill the mu D-Bus server process."
  (unwind-protect
      (when (eq mu4e~dbus-server-status 'spawned)
        (let ((delete-exited-processes t))
          (let* ((buf (get-buffer mu4e~dbus-name))
                 (proc (and (buffer-live-p buf) (get-buffer-process buf))))
            (when proc
              ;; the mu server signal handler will make it quit after 'quit'
              (mu4e~dbus-call-mu '(quit))
              ;; It takes a little time for the "mu dbus" process to unregister
              ;; itself with the D-Bus server.
              (cl-loop for i from 1 upto mu4e~dbus-start-wait-max-count
                       unless (mu4e~dbus-daemon-running-p)
                       return nil
                       when (= i mu4e~dbus-start-wait-max-count)
                       ;; try sending SIGINT (C-c) to process, so it can exit gracefully
                       do (ignore-errors
                            (signal-process proc 'SIGINT))
                       do (apply 'sleep-for mu4e~dbus-start-wait-time))))))
    (setq
     mu4e~dbus-process nil
     mu4e~dbus-buf nil
     mu4e~dbus-server-status nil)))

(defun mu4e~dbus-sentinel (proc _msg)
  "Function that will be called when the mu-dbus process terminates."
  (let ((status (process-status proc)) (code (process-exit-status proc)))
    (setq mu4e~dbus-process nil)
    (setq mu4e~dbus-buf "") ;; clear any half-received sexps
    (cond
     ((eq status 'signal)
      (cond
       ((eq code 9) (message nil))
       ;;(message "the mu server process has been stopped"))
       (t (error (format "mu dbus process received signal %d" code)))))
     ((eq status 'exit)
      (cond
       ((eq code 0)
        (message nil)) ;; don't do anything
       ((eq code 11)
        (error "Database is locked by another process"))
       ((eq code 15)
        (error "Database needs upgrade; try `mu index --rebuild' from the command line"))
       ((eq code 19)
        (error "Database empty; try indexing some messages"))
       (t (error "mu dbus process ended with exit code %d" code))))
     (t
      (error "Something bad happened to the mu dbus process")))))

(defun mu4e-dbus-use-dbus ()
  (interactive)
  (fset 'mu4e~proc-running-p (symbol-function 'mu4e~dbus-running-p))
  (fset 'mu4e~call-mu (symbol-function 'mu4e~dbus-call-mu))
  (fset 'mu4e~proc-kill (symbol-function 'mu4e~dbus-kill)))

(provide 'mu4e-dbus)
;; End of mu4e-dbus.el
