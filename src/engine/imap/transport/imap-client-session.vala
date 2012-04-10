/* Copyright 2011-2012 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

public class Geary.Imap.ClientSession {
    // 30 min keepalive required to maintain session; back off by 1 min for breathing room
    public const int MIN_KEEPALIVE_SEC = 29 * 60;
    
    // NOOP is only sent after this amount of time has passed since the last received
    // message on the connection dependant on connection state (selected/examined vs. authorized)
    public const int DEFAULT_SELECTED_KEEPALIVE_SEC = 60;
    public const int DEFAULT_UNSELECTED_KEEPALIVE_SEC = MIN_KEEPALIVE_SEC;
    public const int DEFAULT_SELECTED_WITH_IDLE_KEEPALIVE_SEC = MIN_KEEPALIVE_SEC;
    
    public enum Context {
        UNCONNECTED,
        UNAUTHORIZED,
        AUTHORIZED,
        SELECTED,
        EXAMINED,
        IN_PROGRESS
    }
    
    public enum DisconnectReason {
        LOCAL_CLOSE,
        LOCAL_ERROR,
        REMOTE_CLOSE,
        REMOTE_ERROR
    }
    
    // Need this because delegates with targets cannot be stored in ADTs.
    private class CommandCallback {
        public unowned SourceFunc callback;
        
        public CommandCallback(SourceFunc callback) {
            this.callback = callback;
        }
    }
    
    private class AsyncCommandResponse {
        public CommandResponse? cmd_response { get; private set; }
        public Object? user { get; private set; }
        public Error? err { get; private set; }
        
        public AsyncCommandResponse(CommandResponse? cmd_response, Object? user, Error? err) {
            this.cmd_response = cmd_response;
            this.user = user;
            this.err = err;
        }
    }
    
    // Many of the async commands go through the FSM, and this is used to pass state around until
    // the multiple transitions are completed
    private class AsyncParams : Object {
        public Cancellable? cancellable;
        public unowned SourceFunc cb;
        public CommandResponse? cmd_response = null;
        public Error? err = null;
        public bool do_yield = false;
        
        public AsyncParams(Cancellable? cancellable, SourceFunc cb) {
            this.cancellable = cancellable;
            this.cb = cb;
        }
    }
    
    private class LoginParams : AsyncParams {
        public string user;
        public string pass;
        
        public LoginParams(string user, string pass, Cancellable? cancellable, SourceFunc cb) {
            base (cancellable, cb);
            
            this.user = user;
            this.pass = pass;
        }
    }
    
    private class SelectParams : AsyncParams {
        public string mailbox;
        public bool is_select;
        
        public SelectParams(string mailbox, bool is_select, Cancellable? cancellable, SourceFunc cb) {
            base (cancellable, cb);
            
            this.mailbox = mailbox;
            this.is_select = is_select;
        }
    }
    
    private class SendCommandParams : AsyncParams {
        public Command cmd;
        
        public SendCommandParams(Command cmd, Cancellable? cancellable, SourceFunc cb) {
            base (cancellable, cb);
            
            this.cmd = cmd;
        }
    }
    
    private enum State {
        // canonical IMAP session states
        DISCONNECTED,
        NOAUTH,
        AUTHORIZED,
        SELECTED,
        LOGGED_OUT,
        
        // transitional states
        CONNECTING,
        AUTHORIZING,
        SELECTING,
        CLOSING_MAILBOX,
        LOGGING_OUT,
        DISCONNECTING,
        
        // terminal state
        BROKEN,
        
        COUNT
    }
    
    private static string state_to_string(uint state) {
        return ((State) state).to_string();
    }
    
    private enum Event {
        // user-initated events
        CONNECT,
        LOGIN,
        SEND_CMD,
        SELECT,
        CLOSE_MAILBOX,
        LOGOUT,
        DISCONNECT,
        
        // async-response events
        CONNECTED,
        CONNECT_DENIED,
        LOGIN_SUCCESS,
        LOGIN_FAILED,
        SENT_COMMAND,
        SEND_COMMAND_FAILED,
        SELECTED,
        SELECT_FAILED,
        CLOSED_MAILBOX,
        CLOSE_MAILBOX_FAILED,
        LOGOUT_SUCCESS,
        LOGOUT_FAILED,
        DISCONNECTED,
        
        // I/O errors
        RECV_ERROR,
        SEND_ERROR,
        
        COUNT;
    }
    
    private static string event_to_string(uint event) {
        return ((Event) event).to_string();
    }
    
    private static Geary.State.MachineDescriptor machine_desc = new Geary.State.MachineDescriptor(
        "Geary.Imap.ClientSession", State.DISCONNECTED, State.COUNT, Event.COUNT,
        state_to_string, event_to_string);
    
    private Geary.Endpoint endpoint;
    private Geary.AccountInformation account_info;
    private Geary.State.Machine fsm;
    private ClientConnection? cx = null;
    private string? current_mailbox = null;
    private bool current_mailbox_readonly = false;
    private Gee.HashMap<Tag, CommandCallback> tag_cb = new Gee.HashMap<Tag, CommandCallback>(
        Hashable.hash_func, Equalable.equal_func);
    private Gee.HashMap<Tag, CommandResponse> tag_response = new Gee.HashMap<Tag, CommandResponse>(
        Hashable.hash_func, Equalable.equal_func);
    private Gee.HashSet<string> current_capabilities = new Gee.HashSet<string>(String.stri_hash,
        String.stri_equal);
    private CommandResponse current_cmd_response = new CommandResponse();
    private uint keepalive_id = 0;
    private int selected_keepalive_secs = 0;
    private int unselected_keepalive_secs = 0;
    private int selected_with_idle_keepalive_secs = 0;
    private bool allow_idle = true;
    private NonblockingMutex serialized_cmds_mutex = new NonblockingMutex();
    private int waiting_to_send = 0;
    
    // state used only during connect and disconnect
    private bool awaiting_connect_response = false;
    private ServerData? connect_response = null;
    private AsyncParams? connect_params = null;
    private AsyncParams? disconnect_params = null;
    
    public virtual signal void connected() {
    }
    
    public virtual signal void authorized() {
    }
    
    public virtual signal void logged_out() {
    }
    
    public virtual signal void login_failed() {
    }
    
    public virtual signal void disconnected(DisconnectReason reason) {
    }
    
    /**
     * If the mailbox name is null it indicates the type of state change that has occurred
     * (authorized -> selected/examined or vice-versa).  If new_name is null readonly should be
     * ignored.
     */
    public virtual signal void current_mailbox_changed(string? old_name, string? new_name, bool readonly) {
    }
    
    public virtual signal void unsolicited_expunged(MessageNumber msg) {
    }
    
    public virtual signal void unsolicited_exists(int exists) {
    }
    
    public virtual signal void unsolicited_recent(int recent) {
    }
    
    public virtual signal void unsolicited_flags(MailboxAttributes attrs) {
    }
    
    public ClientSession(Geary.Endpoint endpoint, Geary.AccountInformation account_info) {
        this.endpoint = endpoint;
        this.account_info = account_info;
        
        Geary.State.Mapping[] mappings = {
            new Geary.State.Mapping(State.DISCONNECTED, Event.CONNECT, on_connect),
            new Geary.State.Mapping(State.DISCONNECTED, Event.LOGIN, on_early_command),
            new Geary.State.Mapping(State.DISCONNECTED, Event.SEND_CMD, on_early_command),
            new Geary.State.Mapping(State.DISCONNECTED, Event.SELECT, on_early_command),
            new Geary.State.Mapping(State.DISCONNECTED, Event.CLOSE_MAILBOX, on_early_command),
            new Geary.State.Mapping(State.DISCONNECTED, Event.LOGOUT, on_early_command),
            new Geary.State.Mapping(State.DISCONNECTED, Event.DISCONNECT, Geary.State.nop),
            
            new Geary.State.Mapping(State.CONNECTING, Event.CONNECT, Geary.State.nop),
            new Geary.State.Mapping(State.CONNECTING, Event.LOGIN, on_early_command),
            new Geary.State.Mapping(State.CONNECTING, Event.SEND_CMD, on_early_command),
            new Geary.State.Mapping(State.CONNECTING, Event.SELECT, on_early_command),
            new Geary.State.Mapping(State.CONNECTING, Event.CLOSE_MAILBOX, on_early_command),
            new Geary.State.Mapping(State.CONNECTING, Event.LOGOUT, on_early_command),
            new Geary.State.Mapping(State.CONNECTING, Event.DISCONNECT, on_disconnect),
            new Geary.State.Mapping(State.CONNECTING, Event.CONNECTED, on_connected),
            new Geary.State.Mapping(State.CONNECTING, Event.CONNECT_DENIED, on_connect_denied),
            new Geary.State.Mapping(State.CONNECTING, Event.SEND_ERROR, on_send_error),
            new Geary.State.Mapping(State.CONNECTING, Event.RECV_ERROR, on_recv_error),
            
            new Geary.State.Mapping(State.NOAUTH, Event.LOGIN, on_login),
            new Geary.State.Mapping(State.NOAUTH, Event.SEND_CMD, on_send_command),
            new Geary.State.Mapping(State.NOAUTH, Event.SELECT, on_unauthenticated),
            new Geary.State.Mapping(State.NOAUTH, Event.CLOSE_MAILBOX, on_unauthenticated),
            new Geary.State.Mapping(State.NOAUTH, Event.LOGOUT, on_logout),
            new Geary.State.Mapping(State.NOAUTH, Event.DISCONNECT, on_disconnect),
            new Geary.State.Mapping(State.NOAUTH, Event.SEND_ERROR, on_send_error),
            new Geary.State.Mapping(State.NOAUTH, Event.RECV_ERROR, on_recv_error),
            
            new Geary.State.Mapping(State.AUTHORIZING, Event.LOGIN, Geary.State.nop),
            new Geary.State.Mapping(State.AUTHORIZING, Event.SEND_CMD, on_send_command),
            new Geary.State.Mapping(State.AUTHORIZING, Event.SELECT, on_unauthenticated),
            new Geary.State.Mapping(State.AUTHORIZING, Event.CLOSE_MAILBOX, on_unauthenticated),
            new Geary.State.Mapping(State.AUTHORIZING, Event.LOGOUT, on_logout),
            new Geary.State.Mapping(State.AUTHORIZING, Event.DISCONNECT, on_disconnect),
            new Geary.State.Mapping(State.AUTHORIZING, Event.LOGIN_SUCCESS, on_login_success),
            new Geary.State.Mapping(State.AUTHORIZING, Event.LOGIN_FAILED, on_login_failed),
            new Geary.State.Mapping(State.AUTHORIZING, Event.SEND_ERROR, on_send_error),
            new Geary.State.Mapping(State.AUTHORIZING, Event.RECV_ERROR, on_recv_error),
            
            new Geary.State.Mapping(State.AUTHORIZED, Event.SEND_CMD, on_send_command),
            new Geary.State.Mapping(State.AUTHORIZED, Event.SELECT, on_select),
            new Geary.State.Mapping(State.AUTHORIZED, Event.CLOSE_MAILBOX, Geary.State.nop),
            new Geary.State.Mapping(State.AUTHORIZED, Event.LOGOUT, on_logout),
            new Geary.State.Mapping(State.AUTHORIZED, Event.DISCONNECT, on_disconnect),
            new Geary.State.Mapping(State.AUTHORIZED, Event.SEND_ERROR, on_send_error),
            new Geary.State.Mapping(State.AUTHORIZED, Event.RECV_ERROR, on_recv_error),
            
            // TODO: technically, if the user selects while selecting, we should handle this
            // in some fashion
            new Geary.State.Mapping(State.SELECTING, Event.SEND_CMD, on_send_command),
            new Geary.State.Mapping(State.SELECTING, Event.SELECT, Geary.State.nop),
            new Geary.State.Mapping(State.SELECTING, Event.CLOSE_MAILBOX, on_close_mailbox),
            new Geary.State.Mapping(State.SELECTING, Event.LOGOUT, on_logout),
            new Geary.State.Mapping(State.SELECTING, Event.DISCONNECT, on_disconnect),
            new Geary.State.Mapping(State.SELECTING, Event.SELECTED, on_selected),
            new Geary.State.Mapping(State.SELECTING, Event.SELECT_FAILED, on_select_failed),
            new Geary.State.Mapping(State.SELECTING, Event.SEND_ERROR, on_send_error),
            new Geary.State.Mapping(State.SELECTING, Event.RECV_ERROR, on_recv_error),
            
            new Geary.State.Mapping(State.SELECTED, Event.SEND_CMD, on_send_command),
            new Geary.State.Mapping(State.SELECTED, Event.SELECT, on_select),
            new Geary.State.Mapping(State.SELECTED, Event.CLOSE_MAILBOX, on_close_mailbox),
            new Geary.State.Mapping(State.SELECTED, Event.LOGOUT, on_logout),
            new Geary.State.Mapping(State.SELECTED, Event.DISCONNECT, on_disconnect),
            new Geary.State.Mapping(State.SELECTED, Event.SEND_ERROR, on_send_error),
            new Geary.State.Mapping(State.SELECTED, Event.RECV_ERROR, on_recv_error),
            
            new Geary.State.Mapping(State.CLOSING_MAILBOX, Event.SEND_CMD, on_send_command),
            new Geary.State.Mapping(State.CLOSING_MAILBOX, Event.CLOSE_MAILBOX, Geary.State.nop),
            new Geary.State.Mapping(State.CLOSING_MAILBOX, Event.DISCONNECT, on_disconnect),
            new Geary.State.Mapping(State.CLOSING_MAILBOX, Event.CLOSED_MAILBOX, on_closed_mailbox),
            new Geary.State.Mapping(State.CLOSING_MAILBOX, Event.CLOSE_MAILBOX_FAILED, on_close_mailbox_failed),
            new Geary.State.Mapping(State.CLOSING_MAILBOX, Event.LOGOUT, on_logout),
            new Geary.State.Mapping(State.CLOSING_MAILBOX, Event.SEND_ERROR, on_send_error),
            new Geary.State.Mapping(State.CLOSING_MAILBOX, Event.RECV_ERROR, on_recv_error),
            
            new Geary.State.Mapping(State.LOGGING_OUT, Event.CONNECT, on_late_command),
            new Geary.State.Mapping(State.LOGGING_OUT, Event.LOGIN, on_late_command),
            new Geary.State.Mapping(State.LOGGING_OUT, Event.SEND_CMD, on_late_command),
            new Geary.State.Mapping(State.LOGGING_OUT, Event.SELECT, on_late_command),
            new Geary.State.Mapping(State.LOGGING_OUT, Event.CLOSE_MAILBOX, on_late_command),
            new Geary.State.Mapping(State.LOGGING_OUT, Event.LOGOUT, Geary.State.nop),
            new Geary.State.Mapping(State.LOGGING_OUT, Event.DISCONNECT, on_disconnect),
            new Geary.State.Mapping(State.LOGGING_OUT, Event.LOGOUT_SUCCESS, on_logged_out),
            new Geary.State.Mapping(State.LOGGING_OUT, Event.LOGOUT_FAILED, Geary.State.nop),
            new Geary.State.Mapping(State.LOGGING_OUT, Event.RECV_ERROR, Geary.State.nop),
            new Geary.State.Mapping(State.LOGGING_OUT, Event.SEND_ERROR, on_send_error),
            
            new Geary.State.Mapping(State.LOGGED_OUT, Event.CONNECT, on_late_command),
            new Geary.State.Mapping(State.LOGGED_OUT, Event.LOGIN, on_late_command),
            new Geary.State.Mapping(State.LOGGED_OUT, Event.SEND_CMD, on_late_command),
            new Geary.State.Mapping(State.LOGGED_OUT, Event.SELECT, on_late_command),
            new Geary.State.Mapping(State.LOGGED_OUT, Event.CLOSE_MAILBOX, on_late_command),
            new Geary.State.Mapping(State.LOGGED_OUT, Event.LOGOUT, on_late_command),
            new Geary.State.Mapping(State.LOGGED_OUT, Event.DISCONNECT, on_disconnect),
            new Geary.State.Mapping(State.LOGGED_OUT, Event.RECV_ERROR, Geary.State.nop),
            new Geary.State.Mapping(State.LOGGED_OUT, Event.SEND_ERROR, on_send_error),
            
            new Geary.State.Mapping(State.DISCONNECTING, Event.CONNECT, on_late_command),
            new Geary.State.Mapping(State.DISCONNECTING, Event.LOGIN, on_late_command),
            new Geary.State.Mapping(State.DISCONNECTING, Event.SEND_CMD, on_late_command),
            new Geary.State.Mapping(State.DISCONNECTING, Event.SELECT, on_late_command),
            new Geary.State.Mapping(State.DISCONNECTING, Event.CLOSE_MAILBOX, on_late_command),
            new Geary.State.Mapping(State.DISCONNECTING, Event.LOGOUT, on_late_command),
            new Geary.State.Mapping(State.DISCONNECTING, Event.DISCONNECTED, on_disconnected),
            new Geary.State.Mapping(State.DISCONNECTING, Event.SEND_ERROR, Geary.State.nop),
            new Geary.State.Mapping(State.DISCONNECTING, Event.RECV_ERROR, Geary.State.nop),
            
            new Geary.State.Mapping(State.BROKEN, Event.CONNECT, on_late_command),
            new Geary.State.Mapping(State.BROKEN, Event.LOGIN, on_late_command),
            new Geary.State.Mapping(State.BROKEN, Event.SEND_CMD, on_late_command),
            new Geary.State.Mapping(State.BROKEN, Event.SELECT, on_late_command),
            new Geary.State.Mapping(State.BROKEN, Event.CLOSE_MAILBOX, on_late_command),
            new Geary.State.Mapping(State.BROKEN, Event.LOGOUT, on_late_command),
            new Geary.State.Mapping(State.BROKEN, Event.DISCONNECT, Geary.State.nop)
        };
        
        fsm = new Geary.State.Machine(machine_desc, mappings, on_ignored_transition);
        fsm.set_logging(false);
    }
    
    ~ClientSession() {
        if (keepalive_id != 0)
            Source.remove(keepalive_id);
    }
    
    public string? get_current_mailbox() {
        return current_mailbox;
    }
    
    public bool is_current_mailbox_readonly() {
        return current_mailbox_readonly;
    }
    
    public Context get_context(out string? current_mailbox) {
        current_mailbox = null;
        
        switch (fsm.get_state()) {
            case State.DISCONNECTED:
            case State.LOGGED_OUT:
            case State.LOGGING_OUT:
            case State.DISCONNECTING:
            case State.BROKEN:
                return Context.UNCONNECTED;
            
            case State.NOAUTH:
                return Context.UNAUTHORIZED;
            
            case State.AUTHORIZED:
                return Context.AUTHORIZED;
            
            case State.SELECTED:
                current_mailbox = this.current_mailbox;
                
                return current_mailbox_readonly ? Context.EXAMINED : Context.SELECTED;
            
            case State.CONNECTING:
            case State.AUTHORIZING:
            case State.SELECTING:
            case State.CLOSING_MAILBOX:
                return Context.IN_PROGRESS;
            
            default:
                assert_not_reached();
        }
    }
    
    //
    // connect
    //
    
    public async void connect_async(Cancellable? cancellable = null) throws Error {
        AsyncParams params = new AsyncParams(cancellable, connect_async.callback);
        fsm.issue(Event.CONNECT, null, params);
        
        if (params.do_yield)
            yield;
        
        if (params.err != null)
            throw params.err;
    }
    
    private uint on_connect(uint state, uint event, void *user, Object? object) {
        assert(object != null);
        
        assert(connect_params == null);
        connect_params = (AsyncParams) object;
        
        assert(cx == null);
        cx = new ClientConnection(endpoint);
        cx.connected.connect(on_network_connected);
        cx.disconnected.connect(on_network_disconnected);
        cx.sent_command.connect(on_network_sent_command);
        cx.flush_failure.connect(on_network_flush_error);
        cx.received_status_response.connect(on_received_status_response);
        cx.received_server_data.connect(on_received_server_data);
        cx.received_bad_response.connect(on_received_bad_response);
        cx.recv_closed.connect(on_received_closed);
        cx.receive_failure.connect(on_network_receive_failure);
        cx.deserialize_failure.connect(on_network_receive_failure);
        
        // only use IDLE when in SELECTED or EXAMINED state
        cx.set_idle_when_quiet(false);
        
        cx.connect_async.begin(connect_params.cancellable, on_connect_completed);
        
        connect_params.do_yield = true;
        
        return State.CONNECTING;
    }
    
    private void on_connect_completed(Object? source, AsyncResult result) {
        assert(connect_params != null);
        
        try {
            cx.connect_async.end(result);
        } catch (Error err) {
            fsm.issue(Event.SEND_ERROR, null, null, err);
            connect_params.err = err;
            
            Scheduler.on_idle(connect_params.cb);
            connect_params = null;
            
            return;
        }
        
        // wait for the initial greeting from the server
        awaiting_connect_response = true;
    }
    
    private bool on_connect_response_received() {
        assert(connect_params != null);
        assert(connect_response != null);
        
        // initial greeting from server is an untagged response where the first parameter is a
        // status code
        try {
            StringParameter status_param = (StringParameter) connect_response.get_as(
                1, typeof(StringParameter));
            if (issue_status(Status.from_parameter(status_param), Event.CONNECTED, Event.CONNECT_DENIED,
                connect_response)) {
                connected();
            }
        } catch (ImapError imap_err) {
            connect_params.err = imap_err;
            fsm.issue(Event.CONNECT_DENIED);
        }
        
        Scheduler.on_idle(connect_params.cb);
        connect_params = null;
        
        return false;
    }
    
    private uint on_connected(uint state, uint event, void *user) {
        return State.NOAUTH;
    }
    
    private uint on_connect_denied(uint state, uint event, void *user) {
        return State.BROKEN;
    }
    
    //
    // login
    //
    
    public async void login_async(Geary.Credentials credentials, Cancellable? cancellable = null)
        throws Error {
        LoginParams params = new LoginParams(credentials.user, credentials.pass, cancellable,
            login_async.callback);
        fsm.issue(Event.LOGIN, null, params);
        
        if (params.do_yield)
            yield;
        
        if (params.err != null)
            throw params.err;
    }
    
    private uint on_login(uint state, uint event, void *user, Object? object) {
        assert(object != null);
        
        LoginParams params = (LoginParams) object;
        
        issue_command_async.begin(new LoginCommand(params.user, params.pass), params,
            params.cancellable, on_login_completed);
        
        params.do_yield = true;
        
        return State.AUTHORIZING;
    }
    
    private void on_login_completed(Object? source, AsyncResult result) {
        if (generic_issue_command_completed(result, Event.LOGIN_SUCCESS, Event.LOGIN_FAILED))
            authorized();
    }
    
    private uint on_login_success(uint state, uint event, void *user) {
        return State.AUTHORIZED;
    }
    
    private uint on_login_failed(uint state, uint event, void *user) {
        login_failed();
        
        return State.NOAUTH;
    }
    
    //
    // keepalives (nop idling to keep the session alive and to periodically receive notifications
    // of changes)
    //
    
    /**
     * If seconds is negative or zero, keepalives will be disabled.  (This is not recommended.)
     *
     * Although keepalives can be enabled at any time, if they're enabled and trigger sending
     * a command prior to connection, error signals may be fired.
     */
    public void enable_keepalives(int seconds_while_selected,
        int seconds_while_unselected, int seconds_while_selected_with_idle) {
        selected_keepalive_secs = seconds_while_selected;
        selected_with_idle_keepalive_secs = seconds_while_selected_with_idle;
        unselected_keepalive_secs = seconds_while_unselected;
        
        // schedule one now, although will be rescheduled if traffic is received before it fires
        schedule_keepalive();
    }
    
    /**
     * Returns true if keepalives are disactivated, false if already disabled.
     */
    public bool disable_keepalives() {
        if (keepalive_id == 0)
            return false;
        
        Source.remove(keepalive_id);
        keepalive_id = 0;
        
        return true;
    }
    
    /**
     * If enabled, an IDLE command will be used for notification of unsolicited server data whenever
     * a mailbox is selected or examined.  IDLE will only be used if ClientSession has seen a
     * CAPABILITY server data response with IDLE listed as a supported extension.
     *
     * This will *not* break a connection out of IDLE mode; a command must be sent as well to force
     * the connection back to de-idled state.
     */
    public void allow_idle_when_selected(bool allow_idle) {
        this.allow_idle = allow_idle;
    }
    
    private void schedule_keepalive() {
        // if old one was scheduled, unschedule and schedule anew
        if (keepalive_id != 0) {
            Source.remove(keepalive_id);
            keepalive_id = 0;
        }
        
        int seconds;
        switch (get_context(null)) {
            case Context.UNCONNECTED:
                return;
            
            case Context.IN_PROGRESS:
            case Context.EXAMINED:
            case Context.SELECTED:
                seconds = (allow_idle && supports_idle()) ? selected_with_idle_keepalive_secs
                    : selected_keepalive_secs;
            break;
            
            case Context.UNAUTHORIZED:
            case Context.AUTHORIZED:
            default:
                seconds = unselected_keepalive_secs;
            break;
        }
        
        // Possible to not have keepalives in one state but in another, or for neither
        //
        // Yes, we allow keepalive to be set to 1 second.  It's their dime.
        if (seconds > 0)
            keepalive_id = Timeout.add_seconds(seconds, on_keepalive);
    }
    
    private bool on_keepalive() {
        debug("Sending keepalive...");
        send_command_async.begin(new NoopCommand(), null, on_keepalive_completed);
        
        // Reschedule to reflect current connection state, although will be rescheduled again if
        // traffic is received
        keepalive_id = 0;
        schedule_keepalive();
        
        return false;
    }
    
    private void on_keepalive_completed(Object? source, AsyncResult result) {
        CommandResponse response;
        try {
            response = send_command_async.end(result);
        } catch (Error err) {
            debug("Keepalive error: %s", err.message);
            
            return;
        }
        
        if (response.status_response.status != Status.OK)
            debug("Keepalive failed: %s", response.status_response.to_string());
    }
    
    //
    // Converters
    //
    
    public bool install_send_converter(Converter converter) {
        return (cx != null) ? cx.install_send_converter(converter) : false;
    }
    
    public bool install_recv_converter(Converter converter) {
        return (cx != null) ? cx.install_recv_converter(converter) : false;
    }
    
    /**
     * ClientSession tracks server extensions reported via the CAPABILITY server data response.
     * This comes automatically when logging in and can be fetched by the CAPABILITY command.
     * ClientSession stores the last seen list as a service for users and uses it internally
     * (specifically for IDLE support).  However, ClientSession will not automatically fetch
     * capabilities, only watch for them as they're reported.  Thus, it's recommended that users
     * of ClientSession issue a CapabilityCommand (if needed) before login.
     *
     * has_capability returns true if the extension was reported.  Some extensions (COMPRESS)
     * report values as well; accessing these will be added in the future.
     */
    public bool has_capability(string name) {
        return current_capabilities.contains(name);
    }
    
    public Gee.Set<string> get_current_capabilities() {
        return current_capabilities.read_only_view;
    }
    
    public bool supports_idle() {
        return has_capability("idle");
    }
    
    //
    // send commands
    //
    
    public async CommandResponse send_command_async(Command cmd, Cancellable? cancellable = null) 
        throws Error {
        // look for special commands that we wish to handle directly, as they affect the state
        // machine
        //
        // TODO: Convert commands into proper calls to avoid throwing an exception
        if (cmd.has_name(LoginCommand.NAME) || cmd.has_name(LogoutCommand.NAME)
            || cmd.has_name(SelectCommand.NAME) || cmd.has_name(ExamineCommand.NAME)
            || cmd.has_name(CloseCommand.NAME)) {
            throw new ImapError.NOT_SUPPORTED("Use direct calls rather than commands");
        }
        
        SendCommandParams params = new SendCommandParams(cmd, cancellable, send_command_async.callback);
        fsm.issue(Event.SEND_CMD, null, params);
        
        if (params.do_yield)
            yield;
        
        if (params.err != null)
            throw params.err;
        
        // Look for unsolicited server data and signal all that are found ... since SELECT/EXAMINE
        // aren't allowed here, don't need to check for them (because their fields aren't considered
        // unsolicited).  Note that this also captures NOOP's responses; although not exactly
        // unsolicited in one sense, the NOOP command is merely the transport vehicle to allow the
        // server to deliver unsolicited messages when no other response is available to piggyback
        // upon.
        //
        // Note that EXPUNGE returns *EXPUNGED* results, not *EXPUNGE*, which is what the unsolicited
        // version is.
        Gee.ArrayList<ServerData>? to_remove = null;
        foreach (ServerData data in params.cmd_response.server_data) {
            UnsolicitedServerData? unsolicited = UnsolicitedServerData.from_server_data(data);
            if (unsolicited != null && report_unsolicited_server_data(unsolicited, "SOLICITED")) {
                if (to_remove == null)
                    to_remove = new Gee.ArrayList<ServerData>();
                
                to_remove.add(data);
            }
        }
        
        if (to_remove != null) {
            bool removed = params.cmd_response.remove_many_server_data(to_remove);
            assert(removed);
        }
        
        return params.cmd_response;
    }
    
    private uint on_send_command(uint state, uint event, void *user, Object? object) {
        assert(object != null);
        
        SendCommandParams params = (SendCommandParams) object;
        
        issue_command_async.begin(params.cmd, params, params.cancellable, on_send_command_completed);
        
        params.do_yield = true;
        
        return state;
    }
    
    private void on_send_command_completed(Object? source, AsyncResult result) {
        generic_issue_command_completed(result, Event.SENT_COMMAND, Event.SEND_COMMAND_FAILED);
    }
    
    //
    // select/examine
    //
    
    public async SelectExamineResults select_async(string mailbox, Cancellable? cancellable = null) 
        throws Error {
        return yield select_examine_async(mailbox, true, cancellable);
    }
    
    public async SelectExamineResults examine_async(string mailbox, Cancellable? cancellable = null)
        throws Error {
        return yield select_examine_async(mailbox, false, cancellable);
    }
    
    public async SelectExamineResults select_examine_async(string mailbox, bool is_select,
        Cancellable? cancellable) throws Error {
        string? old_mailbox = current_mailbox;
        
        SelectParams params = new SelectParams(mailbox, is_select, cancellable,
            select_examine_async.callback);
        fsm.issue(Event.SELECT, null, params);
        
        if (params.do_yield)
            yield;
        
        if (params.err != null)
            throw params.err;
        
        // TODO: We may want to move this signal into the async completion handler rather than
        // fire it here because async callbacks are scheduled on the event loop and their order
        // of execution is not guaranteed
        assert(current_mailbox != null);
        current_mailbox_changed(old_mailbox, current_mailbox, current_mailbox_readonly);
        
        return SelectExamineResults.decode(params.cmd_response);
    }
    
    private uint on_select(uint state, uint event, void *user, Object? object) {
        assert(object != null);
        
        SelectParams params = (SelectParams) object;
        
        if (current_mailbox != null && current_mailbox == params.mailbox)
            return state;
        
        // TODO: Currently don't handle situation where one mailbox is selected and another is
        // asked for without closing
        assert(current_mailbox == null);
        
        Command cmd;
        if (params.is_select)
            cmd = new SelectCommand(params.mailbox);
        else
            cmd = new ExamineCommand(params.mailbox);
        issue_command_async.begin(cmd, params, params.cancellable, on_select_completed);
        
        params.do_yield = true;
        
        return State.SELECTING;
    }
    
    private void on_select_completed(Object? source, AsyncResult result) {
        generic_issue_command_completed(result, Event.SELECTED, Event.SELECT_FAILED);
    }
    
    private uint on_selected(uint state, uint event, void *user, Object? object) {
        assert(object != null);
        
        SelectParams params = (SelectParams) object;
        
        assert(current_mailbox == null);
        current_mailbox = params.mailbox;
        current_mailbox_readonly = !params.is_select;
        
        cx.set_idle_when_quiet(allow_idle && supports_idle());
        
        return State.SELECTED;
    }
    
    private uint on_select_failed(uint state, uint event, void *user, Object? object) {
        assert(object != null);
        
        SelectParams params = (SelectParams) object;
        
        params.err = new ImapError.COMMAND_FAILED("Unable to select mailbox \"%s\": %s",
            params.mailbox, params.cmd_response.to_string());
        
        return State.AUTHORIZED;
    }
    
    //
    // close mailbox
    //
    
    public async void close_mailbox_async(Cancellable? cancellable = null) throws Error {
        string? old_mailbox = current_mailbox;
        
        AsyncParams params = new AsyncParams(cancellable, close_mailbox_async.callback);
        fsm.issue(Event.CLOSE_MAILBOX, null, params);
        
        if (params.do_yield)
            yield;
        
        if (params.err != null)
            throw params.err;
        
        assert(current_mailbox == null);
        
        // possible for a close_mailbox to occur when already closed, but don't fire signal in
        // that case
        //
        // TODO: See note in select_examine_async() for why it might be better to fire this signal
        // in the async completion handler rather than here
        if (old_mailbox != null)
            current_mailbox_changed(old_mailbox, null, false);
    }
    
    private uint on_close_mailbox(uint state, uint event, void *user, Object? object) {
        assert(object != null);
        
        cx.set_idle_when_quiet(false);
        
        AsyncParams params = (AsyncParams) object;
        
        issue_command_async.begin(new CloseCommand(), params, params.cancellable,
            on_close_mailbox_completed);
        
        params.do_yield = true;
        
        return State.CLOSING_MAILBOX;
    }
    
    private void on_close_mailbox_completed(Object? source, AsyncResult result) {
        generic_issue_command_completed(result, Event.CLOSED_MAILBOX, Event.CLOSE_MAILBOX_FAILED);
    }
    
    private uint on_closed_mailbox(uint state, uint event) {
        current_mailbox = null;
        
        return State.AUTHORIZED;
    }
    
    private uint on_close_mailbox_failed(uint state, uint event, void *user, Object? object) {
        assert(object != null);
        
        AsyncParams params = (AsyncParams) object;
        params.err = new ImapError.COMMAND_FAILED("Unable to close mailbox \"%s\": %s",
            current_mailbox, params.cmd_response.to_string());
        
        return State.SELECTED;
    }
    
    //
    // logout
    //
    
    public async void logout_async(Cancellable? cancellable = null) throws Error {
        AsyncParams params = new AsyncParams(cancellable, logout_async.callback);
        fsm.issue(Event.LOGOUT, null, params);
        
        if (params.do_yield)
            yield;
        
        if (params.err != null)
            throw params.err;
    }
    
    private uint on_logout(uint state, uint event, void *user, Object? object) {
        assert(object != null);
        
        AsyncParams params = (AsyncParams) object;
        
        issue_command_async.begin(new LogoutCommand(), params, params.cancellable, on_logout_completed);
        
        params.do_yield = true;
        
        return State.LOGGING_OUT;
    }
    
    private void on_logout_completed(Object? source, AsyncResult result) {
        if (generic_issue_command_completed(result, Event.LOGOUT_SUCCESS, Event.LOGOUT_FAILED))
            logged_out();
    }
    
    private uint on_logged_out(uint state, uint event, void *user) {
        return State.LOGGED_OUT;
    }
    
    //
    // disconnect
    //
    
    public async void disconnect_async(Cancellable? cancellable = null) throws Error {
        AsyncParams params = new AsyncParams(cancellable, disconnect_async.callback);
        fsm.issue(Event.DISCONNECT, null, params);
        
        if (params.do_yield)
            yield;
        
        if (params.err != null)
            throw params.err;
    }
    
    private uint on_disconnect(uint state, uint event, void *user, Object? object) {
        assert(object != null);
        
        assert(disconnect_params == null);
        disconnect_params = (AsyncParams) object;
        
        cx.disconnect_async.begin(disconnect_params.cancellable, on_disconnect_completed);
        
        disconnect_params.do_yield = true;
        
        return State.DISCONNECTING;
    }
    
    private void on_disconnect_completed(Object? source, AsyncResult result) {
        assert(disconnect_params != null);
        
        try {
            cx.disconnect_async.end(result);
            fsm.issue(Event.DISCONNECTED);
            
            disconnected(DisconnectReason.LOCAL_CLOSE);
        } catch (Error err) {
            fsm.issue(Event.SEND_ERROR, null, null, err);
            disconnect_params.err = err;
        }
        
        Scheduler.on_idle(disconnect_params.cb);
        disconnect_params = null;
    }
    
    private uint on_disconnected(uint state, uint event) {
        cx = null;
        
        // although we could go to the DISCONNECTED state, that implies the object can be reused ...
        // while possible, that requires all state (not just the FSM) be reset at this point, and
        // it just seems simpler and less buggy to require the user to discard this object and
        // instantiate a new one
        
        return State.BROKEN;
    }
    
    //
    // error handling
    //
    
    private uint on_send_error(uint state, uint event, void *user, Object? object, Error? err) {
        assert(err != null);
        
        if (err is IOError.CANCELLED)
            return state;
        
        debug("Send error on %s: %s", to_full_string(), err.message);
        
        cx.disconnect_async.begin(null, on_fire_send_error_signal);
        
        return State.BROKEN;
    }
    
    private void on_fire_send_error_signal(Object? object, AsyncResult result) {
        try {
            cx.disconnect_async.end(result);
        } catch (Error err) {
            // ignored
        }
        
        cx = null;
        
        disconnected(DisconnectReason.LOCAL_ERROR);
    }
    
    private uint on_recv_error(uint state, uint event, void *user, Object? object, Error? err) {
        assert(err != null);
        debug("Receive error on %s: %s", to_full_string(), err.message);
        
        cx.disconnect_async.begin(null, on_fire_recv_error_signal);
        
        return State.BROKEN;
    }
    
    private void on_fire_recv_error_signal(Object? object, AsyncResult result) {
        try {
            cx.disconnect_async.end(result);
        } catch (Error err) {
            // ignored
        }
        
        cx = null;
        
        disconnected(DisconnectReason.REMOTE_ERROR);
    }
    
    // This handles the situation where the user submits a command before the connection has been
    // established
    private uint on_early_command(uint state, uint event, void *user, Object? object) {
        assert(object != null);
        
        AsyncParams params = (AsyncParams) object;
        params.err = new ImapError.NOT_CONNECTED("Not connected to %s", to_string());
        
        return state;
    }
    
    // This handles the situation where the user submits a command after the connection has been
    // logged out, terminated, or errored-out
    private uint on_late_command(uint state, uint event, void *user, Object? object) {
        assert(object != null);
        
        AsyncParams params = (AsyncParams) object;
        params.err = new ImapError.NOT_CONNECTED("Connection to %s closing or closed", to_string());
        
        return state;
    }
    
    private uint on_unauthenticated(uint state, uint event, void *user, Object? object) {
        assert(object != null);
        
        AsyncParams params = (AsyncParams) object;
        params.err = new ImapError.UNAUTHENTICATED("Not authenticated with %s", to_string());
        
        return state;
    }
    
    private uint on_ignored_transition(uint state, uint event) {
#if VERBOSE_SESSION
        debug("Ignored transition: %s@%s", fsm.get_event_string(event), fsm.get_state_string(state));
#endif
        
        return state;
    }
    
    //
    // command submission
    //
    
    private bool issue_status(Status status, Event ok_event, Event error_event, Object? object) {
        fsm.issue((status == Status.OK) ? ok_event : error_event, null, object);
        
        return (status == Status.OK);
    }
    
    private async AsyncCommandResponse issue_command_async(Command cmd, Object? user = null,
        Cancellable? cancellable = null) {
        if (cx == null) {
            return new AsyncCommandResponse(null, user,
                new ImapError.NOT_CONNECTED("Not connected to %s", endpoint.to_string()));
        }
        
        int claim_stub = NonblockingMutex.INVALID_TOKEN;
        if (!account_info.imap_server_pipeline) {
            try {
                debug("[%s] Waiting to send cmd %s: %d", to_string(), cmd.to_string(), ++waiting_to_send);
                claim_stub = yield serialized_cmds_mutex.claim_async(cancellable);
                debug("[%s] Ready, now waiting to send cmd %s: %d", to_string(), cmd.to_string(), --waiting_to_send);
            } catch (Error wait_err) {
                return new AsyncCommandResponse(null, user, wait_err);
            }
        }
        
        try {
            yield cx.send_async(cmd, cancellable);
        } catch (Error send_err) {
            try {
                if (!account_info.imap_server_pipeline && claim_stub != NonblockingMutex.INVALID_TOKEN)
                    serialized_cmds_mutex.release(ref claim_stub);
            } catch (Error abort_err) {
                debug("Error attempting to abort from send operation: %s", abort_err.message);
            }
            
            return new AsyncCommandResponse(null, user, send_err);
        }
        
        // If the command didn't complete in the context of send_async(), wait for it
        // now
        if (!tag_response.has_key(cmd.tag)) {
            tag_cb.set(cmd.tag, new CommandCallback(issue_command_async.callback));
            yield;
        }
        
        CommandResponse? cmd_response = tag_response.get(cmd.tag);
        assert(cmd_response != null);
        assert(cmd_response.is_sealed());
        assert(cmd_response.status_response.tag.equals(cmd.tag));
        
        if (!account_info.imap_server_pipeline && claim_stub != NonblockingMutex.INVALID_TOKEN) {
            try {
                serialized_cmds_mutex.release(ref claim_stub);
            } catch (Error notify_err) {
                return new AsyncCommandResponse(null, user, notify_err);
            }
        }
        
        return new AsyncCommandResponse(cmd_response, user, null);
    }
    
    private bool generic_issue_command_completed(AsyncResult result, Event ok_event, Event error_event) {
        AsyncCommandResponse async_response = issue_command_async.end(result);
        
        assert(async_response.user != null);
        AsyncParams params = (AsyncParams) async_response.user;
        
        params.cmd_response = async_response.cmd_response;
        params.err = async_response.err;
        
        bool success;
        if (async_response.err != null) {
            fsm.issue(Event.SEND_ERROR, null, null, async_response.err);
            success = false;
        } else {
            issue_status(async_response.cmd_response.status_response.status, ok_event, error_event,
                params);
            success = true;
        }
        
        Scheduler.on_idle(params.cb);
        
        return success;
    }
    
    private bool report_unsolicited_server_data(UnsolicitedServerData unsolicited, string label) {
        bool reported = false;
        
        if (unsolicited.exists >= 0) {
            debug("%s EXISTS %d", label, unsolicited.exists);
            unsolicited_exists(unsolicited.exists);
            
            reported = true;
        }
        
        if (unsolicited.recent >= 0) {
            debug("%s RECENT %d", label, unsolicited.recent);
            unsolicited_recent(unsolicited.recent);
            
            reported = true;
        }
        
        if (unsolicited.expunge != null) {
            debug("%s EXPUNGE %s", label, unsolicited.expunge.to_string());
            unsolicited_expunged(unsolicited.expunge);
            
            reported = true;
        }
        
        if (unsolicited.flags != null) {
            debug("%s FLAGS %s", label, unsolicited.flags.to_string());
            unsolicited_flags(unsolicited.flags);
            
            reported = true;
        }
        
        return reported;
    }
    
    
    //
    // network connection event handlers
    //
    
    private void on_network_connected() {
#if VERBOSE_SESSION
        debug("Connected to %s", server);
#endif
    }
    
    private void on_network_disconnected() {
#if VERBOSE_SESSION
        debug("Disconnected from %s", server);
#endif
    }
    
    private void on_network_sent_command(Command cmd) {
#if VERBOSE_SESSION
        debug("Sent command %s", cmd.to_string());
#endif
    }
    
    private void on_network_flush_error(Error err) {
        debug("Flush error on %s: %s", to_string(), err.message);
        fsm.issue(Event.SEND_ERROR, null, null, err);
    }
    
    private void on_received_status_response(StatusResponse status_response) {
        // reschedule keepalive, now that traffic has been seen
        schedule_keepalive();
        
        assert(!current_cmd_response.is_sealed());
        current_cmd_response.seal(status_response);
        assert(current_cmd_response.is_sealed());
        
        Tag tag = current_cmd_response.status_response.tag;
        
        // store the result for the caller to index
        assert(!tag_response.has_key(tag));
        tag_response.set(tag, current_cmd_response);
        current_cmd_response = new CommandResponse();
        
        // The caller may not have had a chance to register a callback (if the receive came in in
        // the context of their send_async(), for example), so only schedule if they're yielding
        CommandCallback? cmd_callback = null;
        if (tag_cb.unset(tag, out cmd_callback)) {
            assert(cmd_callback != null);
            Scheduler.on_idle(cmd_callback.callback);
        }
    }
    
    private void on_received_server_data(ServerData server_data) {
        // reschedule keepalive, now that traffic has been seen
        schedule_keepalive();
        
        // Watch for CAPABILITY and store all reported extensions
        StringParameter? name = server_data.get_if_string(1);
        if (name != null && name.equals_ci(CapabilityCommand.NAME)) {
            current_capabilities.clear();
            for (int ctr = 2; ctr < server_data.get_count(); ctr++) {
                StringParameter? param = server_data.get_if_string(ctr);
                if (param != null)
                    current_capabilities.add(param.value.down());
            }
        }
        
        // The first response from the server is an untagged status response, which is considered
        // ServerData in our model.  This captures that and treats it as such.
        if (awaiting_connect_response) {
            awaiting_connect_response = false;
            connect_response = server_data;
            
            Scheduler.on_idle(on_connect_response_received);
            
            return;
        }
        
        // If no outstanding commands, treat as unsolicited so it's reported immediately
        if (tag_cb.size == 0) {
            UnsolicitedServerData? unsolicited = UnsolicitedServerData.from_server_data(server_data);
            if (unsolicited != null && report_unsolicited_server_data(unsolicited, "UNSOLICITED"))
                return;
            
            debug("Received server data for no outstanding cmd: %s", server_data.to_string());
        }
        
        current_cmd_response.add_server_data(server_data);
    }
    
    private void on_received_bad_response(RootParameters root, ImapError err) {
        // reschedule keepalive, now that traffic has been seen
        schedule_keepalive();
        
        debug("Received bad response %s: %s", root.to_string(), err.message);
    }
    
    private void on_received_closed(ClientConnection cx) {
#if VERBOSE_SESSION
        // This currently doesn't generate any Events, but it does mean the connection has closed
        // due to EOS
        debug("Received closed from %s", cx.to_string());
#endif
    }
    
    private void on_network_receive_failure(Error err) {
        debug("Receive failed: %s", err.message);
        fsm.issue(Event.RECV_ERROR, null, null, err);
    }
    
    public string to_string() {
        return "ClientSession:%s".printf((cx == null) ? endpoint.to_string() : cx.to_string());
    }
    
    public string to_full_string() {
        return "%s [%s]".printf(to_string(), fsm.get_state_string(fsm.get_state()));
    }
}

