/* Copyright 2011-2012 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

public class Geary.Imap.ClientConnection {
    public const uint16 DEFAULT_PORT = 143;
    public const uint16 DEFAULT_PORT_TLS = 993;
    
    private const int FLUSH_TIMEOUT_MSEC = 100;
    
    private enum State {
        UNCONNECTED,
        CONNECTED,
        IDLING,
        IDLE,
        DEIDLING,
        DISCONNECTED,
        
        COUNT
    }
    
    private static string state_to_string(uint state) {
        return ((State) state).to_string();
    }
    
    private enum Event {
        CONNECTED,
        DISCONNECTED,
        
        // Use issue_conditional_event() for SEND events, using the result to determine whether
        // or not to continue; the transition handlers do no signalling or I/O
        SEND,
        SEND_IDLE,
        
        // RECVD_* will emit appropriate signals inside their transition handlers; do *not* use
        // issue_conditional_event() for these events
        RECVD_STATUS_RESPONSE,
        RECVD_SERVER_DATA,
        RECVD_CONTINUATION_RESPONSE,
        
        COUNT
    }
    
    private static string event_to_string(uint event) {
        return ((Event) event).to_string();
    }
    
    private static Geary.State.MachineDescriptor machine_desc = new Geary.State.MachineDescriptor(
        "Geary.Imap.ClientConnection", State.UNCONNECTED, State.COUNT, Event.COUNT,
        state_to_string, event_to_string);
    
    // Used solely for debugging
    private static int next_cx_id = 0;
    
    private Geary.Endpoint endpoint;
    private int cx_id;
    private Geary.State.Machine fsm;
    private SocketConnection? cx = null;
    private Serializer? ser = null;
    private Deserializer? des = null;
    private Geary.NonblockingMutex send_mutex = new Geary.NonblockingMutex();
    private int tag_counter = 0;
    private char tag_prefix = 'a';
    private uint flush_timeout_id = 0;
    private bool idle_when_quiet = false;
    private Gee.HashSet<Tag> posted_idle_tags = new Gee.HashSet<Tag>(Hashable.hash_func,
        Equalable.equal_func);
    
    public virtual signal void connected() {
        Logging.debug(Logging.Flag.NETWORK, "[%s] connected to %s", to_string(),
            endpoint.to_string());
    }
    
    public virtual signal void disconnected() {
        Logging.debug(Logging.Flag.NETWORK, "[%s] disconnected from %s", to_string(),
            endpoint.to_string());
    }
    
    public virtual signal void sent_command(Command cmd) {
        Logging.debug(Logging.Flag.NETWORK, "[%s S] %s", to_string(), cmd.to_string());
    }
    
    public virtual signal void flush_failure(Error err) {
        Logging.debug(Logging.Flag.NETWORK, "[%s] flush failure: %s", to_string(), err.message);
    }
    
    public virtual signal void in_idle(bool idling) {
        Logging.debug(Logging.Flag.NETWORK, "[%s] in idle: %s", to_string(), idling.to_string());
    }
    
    public virtual signal void received_status_response(StatusResponse status_response) {
        Logging.debug(Logging.Flag.NETWORK, "[%s R] %s", to_string(), status_response.to_string());
    }
    
    public virtual signal void received_server_data(ServerData server_data) {
        Logging.debug(Logging.Flag.NETWORK, "[%s R] %s", to_string(), server_data.to_string());
    }
    
    public virtual signal void received_continuation_response(ContinuationResponse continuation_response) {
        Logging.debug(Logging.Flag.NETWORK, "[%s R] %s", to_string(), continuation_response.to_string());
    }
    
    public virtual signal void received_unsolicited_server_data(UnsolicitedServerData unsolicited) {
        Logging.debug(Logging.Flag.NETWORK, "[%s R] %s", to_string(), unsolicited.to_string());
    }
    
    public virtual signal void received_bad_response(RootParameters root, ImapError err) {
        Logging.debug(Logging.Flag.NETWORK, "[%s] recv bad response %s: %s", to_string(),
            root.to_string(), err.message);
    }
    
    public virtual signal void recv_closed() {
        Logging.debug(Logging.Flag.NETWORK, "[%s] recv closed", to_string());
    }
    
    public virtual signal void receive_failure(Error err) {
        Logging.debug(Logging.Flag.NETWORK, "[%s] recv failure: %s", to_string(), err.message);
    }
    
    public virtual signal void deserialize_failure(Error err) {
        Logging.debug(Logging.Flag.NETWORK, "[%s] deserialize failure: %s", to_string(),
            err.message);
    }
    
    public ClientConnection(Geary.Endpoint endpoint) {
        this.endpoint = endpoint;
        cx_id = next_cx_id++;
        
        Geary.State.Mapping[] mappings = {
            new Geary.State.Mapping(State.UNCONNECTED, Event.CONNECTED, on_connected),
            new Geary.State.Mapping(State.UNCONNECTED, Event.DISCONNECTED, Geary.State.nop),
            
            new Geary.State.Mapping(State.CONNECTED, Event.SEND, on_proceed),
            new Geary.State.Mapping(State.CONNECTED, Event.SEND_IDLE, on_send_idle),
            new Geary.State.Mapping(State.CONNECTED, Event.RECVD_STATUS_RESPONSE, on_status_response),
            new Geary.State.Mapping(State.CONNECTED, Event.RECVD_SERVER_DATA, on_server_data),
            new Geary.State.Mapping(State.CONNECTED, Event.RECVD_CONTINUATION_RESPONSE, on_continuation),
            new Geary.State.Mapping(State.CONNECTED, Event.DISCONNECTED, on_disconnected),
            
            new Geary.State.Mapping(State.IDLING, Event.SEND, on_idle_send),
            new Geary.State.Mapping(State.IDLING, Event.SEND_IDLE, on_no_proceed),
            new Geary.State.Mapping(State.IDLING, Event.RECVD_STATUS_RESPONSE, on_idle_status_response),
            new Geary.State.Mapping(State.IDLING, Event.RECVD_SERVER_DATA, on_server_data),
            new Geary.State.Mapping(State.IDLING, Event.RECVD_CONTINUATION_RESPONSE, on_idling_continuation),
            new Geary.State.Mapping(State.IDLING, Event.DISCONNECTED, on_disconnected),
            
            new Geary.State.Mapping(State.IDLE, Event.SEND, on_idle_send),
            new Geary.State.Mapping(State.IDLE, Event.SEND_IDLE, on_no_proceed),
            new Geary.State.Mapping(State.IDLE, Event.RECVD_STATUS_RESPONSE, on_idle_status_response),
            new Geary.State.Mapping(State.IDLE, Event.RECVD_SERVER_DATA, on_idle_server_data),
            new Geary.State.Mapping(State.IDLE, Event.RECVD_CONTINUATION_RESPONSE, on_bad_continuation),
            new Geary.State.Mapping(State.IDLE, Event.DISCONNECTED, on_disconnected),
            
            new Geary.State.Mapping(State.DEIDLING, Event.SEND, on_proceed),
            new Geary.State.Mapping(State.DEIDLING, Event.SEND_IDLE, on_send_idle),
            new Geary.State.Mapping(State.DEIDLING, Event.RECVD_STATUS_RESPONSE, on_idle_status_response),
            new Geary.State.Mapping(State.DEIDLING, Event.RECVD_SERVER_DATA, on_idle_server_data),
            new Geary.State.Mapping(State.DEIDLING, Event.RECVD_CONTINUATION_RESPONSE, on_dropped_continuation),
            new Geary.State.Mapping(State.DEIDLING, Event.DISCONNECTED, on_disconnected),
            
            new Geary.State.Mapping(State.DISCONNECTED, Event.SEND, on_no_proceed),
            new Geary.State.Mapping(State.DISCONNECTED, Event.SEND_IDLE, on_no_proceed),
            new Geary.State.Mapping(State.DISCONNECTED, Event.RECVD_STATUS_RESPONSE, on_status_response),
            new Geary.State.Mapping(State.DISCONNECTED, Event.RECVD_SERVER_DATA, on_server_data),
            new Geary.State.Mapping(State.DISCONNECTED, Event.RECVD_CONTINUATION_RESPONSE, on_bad_continuation),
            new Geary.State.Mapping(State.DISCONNECTED, Event.DISCONNECTED, Geary.State.nop)
        };
        
        fsm = new Geary.State.Machine(machine_desc, mappings, on_bad_transition);
        fsm.set_logging(false);
    }
    
    ~ClientConnection() {
        // TODO: Close connection as gracefully as possible
        if (flush_timeout_id != 0)
            Source.remove(flush_timeout_id);
    }
    
    /**
     * Generates a unique tag for the IMAP connection in the form of "<a-z><000-999>".
     */
    private Tag generate_tag() {
        // watch for odometer rollover
        if (++tag_counter >= 1000) {
            tag_counter = 0;
            tag_prefix = (tag_prefix != 'z') ? tag_prefix + 1 : 'a';
        }
        
        // TODO This could be optimized, but we'll leave it for now.
        return new Tag("%c%03d".printf(tag_prefix, tag_counter));
    }
    
    /**
     * When the connection is not sending commands ("quiet"), it will issue an IDLE command to
     * enter a state where unsolicited server data may be sent from the server without resorting
     * to NOOP keepalives.  (Note that keepalives are still required to hold the connection open,
     * according to the IMAP specification.)
     *
     * Note that this will *not* break a connection out of IDLE state alone; a command needs to be
     * flushed down the pipe to do that.  (NOOP would be a good choice.)
     */
    public void set_idle_when_quiet(bool idle_when_quiet) {
        this.idle_when_quiet = idle_when_quiet;
    }
    
    public bool get_idle_when_quiet() {
        return idle_when_quiet;
    }
    
    /**
     * Returns true if the connection is in an IDLE state.  The or_idling parameter means to return
     * true if the connection is working toward an IDLE state (but additional responses are being
     * returned from the server before getting there.
     */
    public bool is_in_idle(bool or_idling) {
        switch (fsm.get_state()) {
            case State.IDLE:
                return true;
            
            case State.IDLING:
                return or_idling;
            
            default:
                return false;
        }
    }
    
    /**
     * Returns silently if a connection is already established.
     */
    public async void connect_async(Cancellable? cancellable = null) throws Error {
        if (cx != null) {
            debug("Already connected to %s", to_string());
            
            return;
        }
        
        cx = yield endpoint.connect_async(cancellable);
        ser = new Serializer(new BufferedOutputStream(cx.output_stream));
        des = new Deserializer(new BufferedInputStream(cx.input_stream));
        des.parameters_ready.connect(on_parameters_ready);
        des.receive_failure.connect(on_receive_failure);
        des.deserialize_failure.connect(on_deserialize_failure);
        des.eos.connect(on_eos);
        
        fsm.issue(Event.CONNECTED);
        
        connected();
        
        des.xon();
    }
    
    public async void disconnect_async(Cancellable? cancellable = null) throws Error {
        if (cx == null)
            return;
        
        des.xoff();
        
        try {
            yield cx.close_async(Priority.DEFAULT, cancellable);
        } finally {
            cx = null;
            ser = null;
            des = null;
            
            fsm.issue(Event.DISCONNECTED);
            
            disconnected();
        }
    }
    
    private void on_parameters_ready(RootParameters root) {
        try {
            ServerResponse.Type response_type;
            ServerResponse response = ServerResponse.from_server(root, out response_type);
            
            switch (response_type) {
                case ServerResponse.Type.STATUS_RESPONSE:
                    fsm.issue(Event.RECVD_STATUS_RESPONSE, null, response);
                break;
                
                case ServerResponse.Type.SERVER_DATA:
                    fsm.issue(Event.RECVD_SERVER_DATA, null, response);
                break;
                
                case ServerResponse.Type.CONTINUATION_RESPONSE:
                    fsm.issue(Event.RECVD_CONTINUATION_RESPONSE, null, response);
                break;
                
                default:
                    assert_not_reached();
            }
        } catch (ImapError err) {
            received_bad_response(root, err);
        }
    }
    
    private void on_receive_failure(Error err) {
        receive_failure(err);
    }
    
    private void on_deserialize_failure() {
        deserialize_failure(new ImapError.PARSE_ERROR("Unable to deserialize from %s", to_string()));
    }
    
    private void on_eos() {
        recv_closed();
    }
    
    public async void send_async(Command cmd, Cancellable? cancellable = null) throws Error {
        check_for_connection();
        
        if (!issue_conditional_event(Event.SEND)) {
            debug("[%s] Send async not allowed", to_string());
            
            throw new ImapError.NOT_CONNECTED("Send not allowed: connection in %s state",
                fsm.get_state_string(fsm.get_state()));
        }
        
        // need to run this in critical section because OutputStreams can only be written to
        // serially
        int token = yield send_mutex.claim_async(cancellable);
        
        // Always assign a new tag; Commands with pre-assigned Tags should not be re-sent.
        // (Do this inside the critical section to ensure commands go out in Tag order; this is not
        // an IMAP requirement but makes tracing commands easier.)
        cmd.assign_tag(generate_tag());
        
        yield cmd.serialize(ser);
        
        send_mutex.release(ref token);
        
        // Reset flush timer so it only fires after n msec after last command pushed out to stream
        if (flush_timeout_id != 0) {
            Source.remove(flush_timeout_id);
            flush_timeout_id = 0;
        }
        
        if (flush_timeout_id == 0)
            flush_timeout_id = Timeout.add_full(Priority.LOW, FLUSH_TIMEOUT_MSEC, on_flush_timeout);
        
        sent_command(cmd);
    }
    
    private bool on_flush_timeout() {
        do_flush_async.begin();
        
        flush_timeout_id = 0;
        
        return false;
    }
    
    private async void do_flush_async() {
        // need to signal when the IDLE command is sent, for completeness
        IdleCommand? idle_cmd = null;
        
        // Like send_async(), need to use mutex when flushing as OutputStream must be accessed in
        // serialized fashion
        int token = NonblockingMutex.INVALID_TOKEN;
        try {
            token = yield send_mutex.claim_async();
            
            // as connection is "quiet" (haven't seen new command in n msec), go into IDLE state
            // if (a) allowed by owner and (b) allowed by state machine
            if (ser != null && idle_when_quiet && issue_conditional_event(Event.SEND_IDLE)) {
                idle_cmd = new IdleCommand();
                idle_cmd.assign_tag(generate_tag());
                
                // store IDLE tag to watch for response later (many responses could arrive before it)
                bool added = posted_idle_tags.add(idle_cmd.tag);
                assert(added);
                
                Logging.debug(Logging.Flag.NETWORK, "[%s] Initiating IDLE: %s", to_string(),
                    idle_cmd.to_string());
                
                yield idle_cmd.serialize(ser);
            } else if (idle_when_quiet) {
                debug("[%s] Flush w/o initiating IDLE", to_string());
            }
            
            if (ser != null)
                yield ser.flush_async();
        } catch (Error err) {
            idle_cmd = null;
            flush_failure(err);
        } finally {
            if (token != NonblockingMutex.INVALID_TOKEN) {
                try {
                    send_mutex.release(ref token);
                } catch (Error err2) {
                    // ignored
                }
            }
        }
        
        if (idle_cmd != null)
            sent_command(idle_cmd);
    }
    
    private void check_for_connection() throws Error {
        if (cx == null)
            throw new ImapError.NOT_CONNECTED("Not connected to %s", to_string());
    }
    
    public string to_string() {
        if (cx != null) {
            try {
                return "%04X/%s/%s".printf(cx_id,
                    Inet.address_to_string((InetSocketAddress) cx.get_remote_address()),
                    fsm.get_state_string(fsm.get_state()));
            } catch (Error err) {
                // fall through
            }
        }
        
        return "%04X/%s/%s".printf(cx_id, endpoint.to_string(), fsm.get_state_string(fsm.get_state()));
    }
    
    //
    // transition handlers
    //
    
    private bool issue_conditional_event(Event event) {
        bool proceed = false;
        fsm.issue(event, &proceed);
        
        return proceed;
    }
    
    private void signal_server_data(void *user, Object? object) {
        received_server_data((ServerData) object);
    }
    
    private void signal_status_response(void *user, Object? object) {
        received_status_response((StatusResponse) object);
    }
    
    private void signal_continuation(void *user, Object? object) {
        received_continuation_response((ContinuationResponse) object);
    }
    
    private void signal_unsolicited_server_data(void *user, Object? object) {
        received_unsolicited_server_data((UnsolicitedServerData) object);
    }
    
    private void signal_entered_idle() {
        in_idle(true);
    }
    
    private void signal_left_idle() {
        in_idle(false);
    }
    
    private uint do_proceed(uint state, void *user) {
        *((bool *) user) = true;
        
        return state;
    }
    
    private uint do_no_proceed(uint state, void *user) {
        *((bool *) user) = false;
        
        return state;
    }
    
    private uint on_proceed(uint state, uint event, void *user) {
        return do_proceed(state, user);
    }
    
    private uint on_no_proceed(uint state, uint event, void *user) {
        return do_no_proceed(state, user);
    }
    
    private uint on_connected(uint state, uint event, void *user) {
        return State.CONNECTED;
    }
    
    private uint on_disconnected(uint state, uint event, void *user) {
        return State.DISCONNECTED;
    }
    
    private uint on_send_idle(uint state, uint event, void *user) {
        return do_proceed(State.IDLING, user);
    }
    
    private uint on_status_response(uint state, uint event, void *user, Object? object) {
        fsm.do_post_transition(signal_status_response, user, object);
        
        return state;
    }
    
    private uint on_server_data(uint state, uint event, void *user, Object? object) {
        fsm.do_post_transition(signal_server_data, user, object);
        
        return state;
    }
    
    private uint on_continuation(uint state, uint event, void *user, Object? object) {
        fsm.do_post_transition(signal_continuation, user, object);
        
        return state;
    }
    
    private uint on_idling_continuation(uint state, uint event, void *user, Object? object) {
        ContinuationResponse continuation = (ContinuationResponse) object;
        
        Logging.debug(Logging.Flag.NETWORK, "[%s] Entering IDLE: %s", to_string(),
            continuation.to_string());
        
        // only signal entering IDLE state if that's the case
        if (state != State.IDLE)
            fsm.do_post_transition(signal_entered_idle);
        
        return State.IDLE;
    }
    
    private uint on_idle_send(uint state, uint event, void *user) {
        Logging.debug(Logging.Flag.NETWORK, "[%s] Closing IDLE", to_string());
        
        try {
            ser.push_string("done");
            ser.push_eol();
        } catch (Error err) {
            debug("[%s] Unable to close IDLE: %s", to_string(), err.message);
            
            return do_no_proceed(state, user);
        }
        
        // only signal leaving IDLE state if that's the case
        if (state == State.IDLE)
            fsm.do_post_transition(signal_left_idle);
        
        return do_proceed(State.DEIDLING, user);
    }
    
    private uint on_idle_status_response(uint state, uint event, void *user, Object? object) {
        StatusResponse status_response = (StatusResponse) object;
        
        // if not a post IDLE tag, then treat as external status response
        if (!posted_idle_tags.remove(status_response.tag)) {
            fsm.do_post_transition(signal_status_response, user, object);
            
            return state;
        }
        
        // StatusResponse for one of our IDLE commands; either way, no longer in IDLE mode
        if (status_response.status == Status.OK) {
            Logging.debug(Logging.Flag.NETWORK, "[%s] Leaving IDLE: %s", to_string(),
                status_response.to_string());
        } else {
            Logging.debug(Logging.Flag.NETWORK, "[%s] Unable to enter IDLE: %s", to_string(),
                status_response.to_string());
        }
        
        // Only return to CONNECTED if no other IDLE commands are outstanding (and only signal
        // if leaving IDLE state for another)
        uint next = (posted_idle_tags.size == 0) ? State.CONNECTED : state;
        
        if (state == State.IDLE && next != State.IDLE)
            fsm.do_post_transition(signal_left_idle);
        
        return next;
    }
    
    private uint on_idle_server_data(uint state, uint event, void *user, Object? object) {
        // all server data received during IDLE is, by definition, unsolicited server data
        UnsolicitedServerData? unsolicited = UnsolicitedServerData.from_server_data((ServerData) object);
        if (unsolicited == null) {
            Logging.debug(Logging.Flag.NETWORK, "[%s] Unknown unsolicited server data: %s",
                to_string(), ((ServerData) object).to_string());
            
            return state;
        }
        
        fsm.do_post_transition(signal_unsolicited_server_data, user, unsolicited);
        
        return state;
    }
    
    private uint on_dropped_continuation(uint state, uint event, void *user, Object? object) {
        // Continuation received while de-idling, this is due to prior IDLE finally catching up with
        // the receive channel, ignore as the IDLE will be dropped momentarily from the "done"
        // previously sent
        Logging.debug(Logging.Flag.NETWORK, "[%s] Continuation received, dropped: %s", to_string(),
            ((ContinuationResponse) object).to_string());
        
        return state;
    }
    
    private uint on_bad_continuation(uint state, uint event, void *user, Object? object) {
        debug("[%s] Bad continuation received: %s", to_string(),
            ((ContinuationResponse) object).to_string());
        
        return state;
    }
    
    private uint on_bad_transition(uint state, uint event, void *user) {
        debug("[%s] Bad cx state transition %s", to_string(), fsm.get_event_issued_string(state, event));
        
        return on_no_proceed(state, event, user);
    }
}

