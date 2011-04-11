/* Copyright 2011 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

errordomain CommandException {
    USAGE,
    STATE
}

class ImapConsole : Gtk.Window {
    private Gtk.TextView console = new Gtk.TextView();
    private Gtk.Entry cmdline = new Gtk.Entry();
    private Gtk.Statusbar statusbar = new Gtk.Statusbar();
    
    private uint statusbar_ctx = 0;
    private uint statusbar_msg_id = 0;
    
    private Geary.Imap.ClientSession session = new Geary.Imap.ClientSession();
    private Geary.Imap.ClientConnection? cx = null;
    
    public ImapConsole() {
        title = "IMAP Console";
        destroy.connect(() => { Gtk.main_quit(); });
        set_default_size(800, 600);
        
        Gtk.VBox layout = new Gtk.VBox(false, 4);
        
        console.editable = false;
        Gtk.ScrolledWindow scrolled_console = new Gtk.ScrolledWindow(null, null);
        scrolled_console.add(console);
        scrolled_console.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC);
        layout.pack_start(scrolled_console, true, true, 0);
        
        cmdline.activate.connect(on_activate);
        layout.pack_start(cmdline, false, false, 0);
        
        statusbar_ctx = statusbar.get_context_id("status");
        statusbar.has_resize_grip = true;
        layout.pack_end(statusbar, false, false, 0);
        
        add(layout);
        
        cmdline.grab_focus();
    }
    
    private void on_activate() {
        exec(cmdline.buffer.text);
        cmdline.buffer.delete_text(0, -1);
    }
    
    private void clear_status() {
        if (statusbar_msg_id == 0)
            return;
        
        statusbar.remove(statusbar_ctx, statusbar_msg_id);
        statusbar_msg_id = 0;
    }
    
    private void status(string text) {
        clear_status();
        
        string msg = text;
        if (!msg.has_suffix(".") && !msg.has_prefix("usage"))
            msg += ".";
        
        statusbar_msg_id = statusbar.push(statusbar_ctx, msg);
    }
    
    private void exception(Error err) {
        status(err.message);
    }
    
    private void exec(string input) {
        string[] lines = input.strip().split(";");
        foreach (string line in lines) {
            string[] tokens = line.strip().split(" ");
            if (tokens.length == 0)
                continue;
            
            string cmd = tokens[0].strip().down();
            
            string[] args = new string[0];
            for (int ctr = 1; ctr < tokens.length; ctr++) {
                string arg = tokens[ctr].strip();
                if (!is_empty_string(arg))
                    args += arg;
            }
            
            clear_status();
            
            try {
                switch (cmd) {
                    case "noop":
                    case "nop":
                        noop(cmd, args);
                    break;
                    
                    case "capabilities":
                    case "caps":
                        capabilities(cmd, args);
                    break;
                    
                    case "connect":
                        connect_cmd(cmd, args);
                    break;
                    
                    case "disconnect":
                        disconnect_cmd(cmd, args);
                    break;
                    
                    case "login":
                        login(cmd, args);
                    break;
                    
                    case "logout":
                    case "bye":
                    case "kthxbye":
                        logout(cmd, args);
                    break;
                    
                    case "list":
                        list(cmd, args);
                    break;
                    
                    case "examine":
                        examine(cmd, args);
                    break;
                    
                    case "exit":
                    case "quit":
                        quit(cmd, args);
                    break;
                    
                    case "gmail":
                        string[] fake_args = new string[1];
                        fake_args[0] = "imap.gmail.com:993";
                        connect_cmd("connect", fake_args);
                    break;
                    
                    default:
                        status("Unknown command \"%s\"".printf(cmd));
                    break;
                }
            } catch (Error ce) {
                status(ce.message);
            }
        }
    }
    
    private void check_args(string cmd, string[] args, int count, string? usage) throws CommandException {
        if (args.length != count)
            throw new CommandException.USAGE("usage: %s %s", cmd, usage != null ? usage : "");
    }
    
    private void check_connected(string cmd, string[] args, int count, string? usage) throws CommandException {
        if (cx == null)
            throw new CommandException.STATE("'connect' required");
        
        check_args(cmd, args, count, usage);
    }
    
    private void capabilities(string cmd, string[] args) throws Error {
        check_connected(cmd, args, 0, null);
        
        cx.send_async.begin(new Geary.Imap.CapabilityCommand(session), Priority.DEFAULT, null,
            on_capabilities);
    }
    
    private void on_capabilities(Object? source, AsyncResult result) {
        try {
            cx.send_async.end(result);
            status("Success");
        } catch (Error err) {
            exception(err);
        }
    }
    
    private void noop(string cmd, string[] args) throws Error {
        check_connected(cmd, args, 0, null);
        
        cx.send_async.begin(new Geary.Imap.NoopCommand(session), Priority.DEFAULT, null,
            on_noop);
    }
    
    private void on_noop(Object? source, AsyncResult result) {
        try {
            cx.send_async.end(result);
            status("Success");
        } catch (Error err) {
            exception(err);
        }
    }
    
    private void connect_cmd(string cmd, string[] args) throws Error {
        if (cx != null)
            throw new CommandException.STATE("'logout' required");
        
        check_args(cmd, args, 1, "hostname[:port]");
        
        cx = new Geary.Imap.ClientConnection(args[0], Geary.Imap.ClientConnection.DEFAULT_PORT);
        
        status("Connecting to %s...".printf(args[0]));
        cx.connect_async.begin(null, on_connected);
    }
    
    private void on_connected(Object? source, AsyncResult result) {
        try {
            cx.connect_async.end(result);
            status("Connected");
        
            cx.sent_command.connect(on_sent_command);
            cx.received_response.connect(on_received_response);
            cx.xon();
            
        } catch (Error err) {
            cx = null;
            
            exception(err);
        }
    }
    
    private void disconnect_cmd(string cmd, string[] args) throws Error {
        check_connected(cmd, args, 0, null);
        
        status("Disconnecting...");
        cx.disconnect_async.begin(null, on_disconnected);
    }
    
    private void on_disconnected(Object? source, AsyncResult result) {
        try {
            cx.disconnect_async.end(result);
            status("Disconnected");
            
            cx.sent_command.disconnect(on_sent_command);
            cx = null;
        } catch (Error err) {
            exception(err);
        }
    }
    
    private void login(string cmd, string[] args) throws Error {
        check_connected(cmd, args, 2, "user pass");
        
        status("Logging in...");
        cx.post(new Geary.Imap.LoginCommand(session, args[0], args[1]), on_logged_in);
    }
    
    private void on_logged_in(Object? source, AsyncResult result) {
        try {
            cx.finish_post(result);
        } catch (Error err) {
            exception(err);
        }
    }
    
    private void logout(string cmd, string[] args) throws Error {
        check_connected(cmd, args, 0, null);
        
        status("Logging out...");
        cx.post(new Geary.Imap.LogoutCommand(session), on_logout);
    }
    
    private void on_logout(Object? source, AsyncResult result) {
        try {
            cx.finish_post(result);
            status("Logged out");
        } catch (Error err) {
            exception(err);
        }
    }
    
    private void list(string cmd, string[] args) throws Error {
        check_connected(cmd, args, 2, "<reference> <mailbox>");
        
        status("Listing...");
        cx.post(new Geary.Imap.ListCommand.wildcarded(session, args[0], args[1]), on_list);
    }
    
    private void on_list(Object? source, AsyncResult result) {
        try {
            cx.finish_post(result);
            status("Listed");
        } catch (Error err) {
            exception(err);
        }
    }
    
    private void examine(string cmd, string[] args) throws Error {
        check_connected(cmd, args, 1, "<mailbox>");
        
        status("Opening %s read-only".printf(args[0]));
        cx.post(new Geary.Imap.ExamineCommand(session, args[0]), on_examine);
    }
    
    private void on_examine(Object? source, AsyncResult result) {
        try {
            cx.finish_post(result);
            status("Opened read-only");
        } catch (Error err) {
            exception(err);
        }
    }
    
    private void quit(string cmd, string[] args) throws Error {
        Gtk.main_quit();
    }
    
    private void on_sent_command(Geary.Imap.Command cmd) {
        append_to_console("[L] ");
        append_to_console(cmd.to_string());
        append_to_console("\n");
    }
    
    private void on_received_response(Geary.Imap.RootParameters params) {
        append_to_console("[R] ");
        append_to_console(params.to_string());
        append_to_console("\n");
    }
    
    private void append_to_console(string text) {
        Gtk.TextIter iter;
        console.buffer.get_iter_at_offset(out iter, -1);
        console.buffer.insert(iter, text, -1);
    }
}

void main(string[] args) {
    Gtk.init(ref args);
    
    ImapConsole console = new ImapConsole();
    console.show_all();
    
    Gtk.main();
}

