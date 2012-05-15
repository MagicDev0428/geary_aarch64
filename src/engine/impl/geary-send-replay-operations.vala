/* Copyright 2011-2012 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

private class Geary.MarkEmail : Geary.SendReplayOperation {
    private GenericImapFolder engine;
    private Gee.List<Geary.EmailIdentifier> to_mark;
    private Geary.EmailFlags? flags_to_add;
    private Geary.EmailFlags? flags_to_remove;
    private Gee.Map<Geary.EmailIdentifier, Geary.EmailFlags>? original_flags = null;
    private Cancellable? cancellable;
    
    public MarkEmail(GenericImapFolder engine, Gee.List<Geary.EmailIdentifier> to_mark, 
        Geary.EmailFlags? flags_to_add, Geary.EmailFlags? flags_to_remove, 
        Cancellable? cancellable = null) {
        base("MarkEmail");
        
        this.engine = engine;
        
        this.to_mark = to_mark;
        this.flags_to_add = flags_to_add;
        this.flags_to_remove = flags_to_remove;
        this.cancellable = cancellable;
    }
    
    public override async bool replay_local() throws Error {
        Logging.debug(Logging.Flag.OPERATIONS, "MarkEmail.replay_local %s: %d email IDs add=%s remove=%s",
            engine.to_string(), to_mark.size,
            (flags_to_add != null) ? flags_to_add.to_string() : "(none)",
            (flags_to_remove != null) ? flags_to_remove.to_string() : "(none)");
        
        // Save original flags, then set new ones.
        original_flags = yield engine.local_folder.get_email_flags_async(to_mark, cancellable);
        yield engine.local_folder.mark_email_async(to_mark, flags_to_add, flags_to_remove,
            cancellable);
        
        // Notify using flags from DB.
        engine.notify_email_flags_changed(yield engine.local_folder.get_email_flags_async(to_mark,
            cancellable));
        
        return false;
    }
    
    public override async bool replay_remote() throws Error {
        Logging.debug(Logging.Flag.OPERATIONS, "MarkEmail.replay_remote %s: %d email IDs add=%d remove=%d",
            engine.to_string(), to_mark.size,
            (flags_to_add != null) ? flags_to_add.to_string() : "(none)",
            (flags_to_remove != null) ? flags_to_remove.to_string() : "(none)");
        
        yield engine.remote_folder.mark_email_async(new Imap.MessageSet.email_id_collection(to_mark),
            flags_to_add, flags_to_remove, cancellable);
        
        return true;
    }
    
    public override async void backout_local() throws Error {
        // Restore original flags.
        yield engine.local_folder.set_email_flags_async(original_flags, cancellable);
    }
}

private class Geary.RemoveEmail : Geary.SendReplayOperation {
    private GenericImapFolder engine;
    private Gee.List<Geary.EmailIdentifier> to_remove;
    private Cancellable? cancellable;
    private int original_count = 0;
    
    public RemoveEmail(GenericImapFolder engine, Gee.List<Geary.EmailIdentifier> to_remove,
        Cancellable? cancellable = null) {
        base("RemoveEmail");
        
        this.engine = engine;
        
        this.to_remove = to_remove;
        this.cancellable = cancellable;
    }
    
    public override async bool replay_local() throws Error {
        Logging.debug(Logging.Flag.OPERATIONS, "RemoveEmail.replay_local %s: %d Email IDs", engine.to_string(),
            to_remove.size);
        
        // TODO: Use a local_folder method that operates on all messages at once
        foreach (Geary.EmailIdentifier id in to_remove)
            yield engine.local_folder.mark_removed_async(id, true, cancellable);
        
        engine.notify_email_removed(to_remove);
        
        original_count = engine.remote_count;
        engine.notify_email_count_changed(original_count - to_remove.size,
            Geary.Folder.CountChangeReason.REMOVED);
        
        return false;
    }
    
    public override async bool replay_remote() throws Error {
        Logging.debug(Logging.Flag.OPERATIONS, "RemoveEmail.replay_remote %s: %d Email IDs", engine.to_string(),
            to_remove.size);
        
        // Remove from server. Note that this causes the receive replay queue to kick into
        // action, removing the e-mail but *NOT* firing a signal; the "remove marker" indicates
        // that the signal has already been fired.
        yield engine.remote_folder.remove_email_async(new Imap.MessageSet.email_id_collection(to_remove),
            cancellable);
        
        return true;
    }
    
    public override async void backout_local() throws Error {
        // TODO: Use a local_folder method that operates on all messages at once
        foreach (Geary.EmailIdentifier id in to_remove)
            yield engine.local_folder.mark_removed_async(id, false, cancellable);
        
        engine.notify_email_appended(to_remove);
        engine.notify_email_count_changed(original_count, Geary.Folder.CountChangeReason.ADDED);
    }
}

private class Geary.ListEmail : Geary.SendReplayOperation {
    private class RemoteListPositional : NonblockingBatchOperation {
        private ListEmail owner;
        private int[] needed_by_position;
        
        public RemoteListPositional(ListEmail owner, int[] needed_by_position) {
            this.owner = owner;
            this.needed_by_position = needed_by_position;
        }
        
        public override async Object? execute_async(Cancellable? cancellable) throws Error {
            yield owner.remote_list_positional(needed_by_position);
            
            return null;
        }
    }
    
    private class RemoteListPartial : NonblockingBatchOperation {
        private ListEmail owner;
        private Geary.Email.Field remaining_fields;
        private Gee.Collection<EmailIdentifier> ids;
        
        public RemoteListPartial(ListEmail owner, Geary.Email.Field remaining_fields,
            Gee.Collection<EmailIdentifier> ids) {
            this.owner = owner;
            this.remaining_fields = remaining_fields;
            this.ids = ids;
        }
        
        public override async Object? execute_async(Cancellable? cancellable) throws Error {
            yield owner.remote_list_partials(ids, remaining_fields);
            
            return null;
        }
    }
    
    protected GenericImapFolder engine;
    protected int low;
    protected int count;
    protected Geary.Email.Field required_fields;
    protected Gee.List<Geary.Email>? accumulator = null;
    protected weak EmailCallback? cb;
    protected Cancellable? cancellable;
    protected bool local_only;
    protected bool remote_only;
    
    private Gee.List<Geary.Email>? local_list = null;
    private int local_list_size = 0;
    private Gee.HashMultiMap<Geary.Email.Field, Geary.EmailIdentifier> unfulfilled = new Gee.HashMultiMap<
        Geary.Email.Field, Geary.EmailIdentifier>();
    
    public ListEmail(GenericImapFolder engine, int low, int count, Geary.Email.Field required_fields,
        Gee.List<Geary.Email>? accumulator, EmailCallback? cb, Cancellable? cancellable,
        bool local_only, bool remote_only) {
        base("ListEmail");
        
        this.engine = engine;
        this.low = low;
        this.count = count;
        this.required_fields = required_fields;
        this.accumulator = accumulator;
        this.cb = cb;
        this.cancellable = cancellable;
        this.local_only = local_only;
        this.remote_only = remote_only;
    }
    
    public override async bool replay_local() throws Error {
        int local_count;
        if (!local_only) {
            // normalize the position (ordering) of what's available locally with the situation on
            // the server ... this involves prefetching the PROPERTIES of the missing emails from
            // the server and caching them locally
            yield engine.normalize_email_positions_async(low, count, out local_count, cancellable);
        } else {
            // local_only means just that
            local_count = yield engine.local_folder.get_email_count_async(cancellable);
        }
        
        // normalize the arguments so they reflect cardinal positions ... remote_count can be -1
        // if the folder is in the process of opening
        int local_low;
        if (!local_only && (yield engine.wait_for_remote_to_open(cancellable)) &&
            engine.remote_count >= 0) {
            engine.normalize_span_specifiers(ref low, ref count, engine.remote_count);
            
            // because the local store caches messages starting from the newest (at the end of the list)
            // to the earliest fetched by the user, need to adjust the low value to match its offset
            // and range
            local_low = engine.remote_position_to_local_position(low, local_count);
        } else {
            engine.normalize_span_specifiers(ref low, ref count, local_count);
            local_low = low.clamp(1, local_count);
        }
        
        Logging.debug(Logging.Flag.OPERATIONS,
            "ListEmail.replay_local %s: low=%d count=%d local_count=%d remote_count=%d local_low=%d",
            engine.to_string(), low, count, local_count, engine.remote_count, local_low);
        
        if (!remote_only && local_low > 0) {
            try {
                local_list = yield engine.local_folder.list_email_async(local_low, count, required_fields,
                    Geary.Folder.ListFlags.NONE, true, cancellable);
            } catch (Error local_err) {
                if (cb != null && !(local_err is IOError.CANCELLED))
                    cb (null, local_err);
                throw local_err;
            }
        }
        
        local_list_size = (local_list != null) ? local_list.size : 0;
        
        Logging.debug(Logging.Flag.OPERATIONS, "Fetched %d emails from local store for %s",
            local_list_size, engine.to_string());
        
        // fixup local email positions to match server's positions
        if (local_list_size > 0 && engine.remote_count > 0 && local_count < engine.remote_count) {
            int adjustment = engine.remote_count - local_count;
            foreach (Geary.Email email in local_list)
                email.update_position(email.position + adjustment);
        }
        
        // Break into two pools: a list of emails where all field requirements are met and a hash
        // table of messages keyed by what fields are required
        Gee.List<Geary.Email> fulfilled = new Gee.ArrayList<Geary.Email>();
        if (local_list_size > 0) {
            foreach (Geary.Email email in local_list) {
                if (email.fields.fulfills(required_fields)) {
                    fulfilled.add(email);
                } else {
                    // strip fulfilled fields so only remaining are fetched from server
                    Geary.Email.Field remaining = required_fields.clear(email.fields);
                    unfulfilled.set(remaining, email.id);
                }
            }
        }
        
        // report fulfilled
        if (fulfilled.size > 0) {
            if (accumulator != null)
                accumulator.add_all(fulfilled);
            
            if (cb != null)
                cb(fulfilled, null);
        }
        
        // if local list matches total asked for, or if only returning local versions, exit
        if (fulfilled.size == count || local_only) {
            if (!local_only)
                assert(unfulfilled.size == 0);
            
            if (cb != null)
                cb(null, null);
            
            return true;
        }
        
        return false;
    }
    
    public override async bool replay_remote() throws Error {
        // go through the positions from (low) to (low + count) and see if they're not already
        // present in local_list; whatever isn't present needs to be fetched in full
        //
        // TODO: This is inefficient because we can't assume the returned emails are sorted or
        // contiguous (it's possible local email is present but doesn't fulfill all the fields).
        // A better search method is probably possible, but this will do for now
        int[] needed_by_position = new int[0];
        for (int position = low; position <= (low + (count - 1)); position++) {
            bool found = false;
            for (int ctr = 0; ctr < local_list_size; ctr++) {
                if (local_list[ctr].position == position) {
                    found = true;
                    
                    break;
                }
            }
            
            if (!found)
                needed_by_position += position;
        }
        
        Logging.debug(Logging.Flag.OPERATIONS, "ListEmail.replay_remote %s: %d by position, %d unfulfilled",
            engine.to_string(), needed_by_position.length, unfulfilled.get_values().size);
        
        NonblockingBatch batch = new NonblockingBatch();
        
        // fetch in full whatever is needed wholesale
        if (needed_by_position.length > 0)
            batch.add(new RemoteListPositional(this, needed_by_position));
        
        // fetch the partial emails that do not fulfill all required fields, getting only those
        // fields that are missing for each email
        if (unfulfilled.size > 0) {
            foreach (Geary.Email.Field remaining_fields in unfulfilled.get_keys())
                batch.add(new RemoteListPartial(this, remaining_fields, unfulfilled.get(remaining_fields)));
        }
        
        Logging.debug(Logging.Flag.OPERATIONS, "ListEmail.replay_remote %s: Scheduling %d FETCH operations",
            engine.to_string(), batch.size);
        
        yield batch.execute_all_async(cancellable);
        
        // Notify of first error encountered before throwing
        if (cb != null && batch.first_exception != null)
            cb(null, batch.first_exception);
        
        batch.throw_first_exception();
        
        // signal finished
        if (cb != null)
            cb(null, null);
        
        return true;
    }
    
    private async void remote_list_positional(int[] needed_by_position) throws Error {
        // possible to call remote multiple times, wait for it to open once and go
        if (!yield engine.wait_for_remote_to_open(cancellable))
            return;
        
        // pull in reverse order because callers to this method tend to order messages from oldest
        // to newest, but for user satisfaction, should be fetched from newest to oldest
        int remaining = needed_by_position.length;
        while (remaining > 0) {
            // if a callback is specified, pull the messages down in chunks, so they can be reported
            // incrementally
            int[] list;
            if (cb != null) {
                int list_count = int.min(GenericImapFolder.REMOTE_FETCH_CHUNK_COUNT, remaining);
                list = needed_by_position[remaining - list_count:remaining];
                assert(list.length == list_count);
            } else {
                list = needed_by_position;
            }
            
            // pull from server
            Gee.List<Geary.Email>? remote_list = yield engine.remote_folder.list_email_async(
                new Imap.MessageSet.sparse(list), required_fields, cancellable);
            if (remote_list == null || remote_list.size == 0)
                break;
            
            // if any were fetched, store locally ... must be stored before they can be reported
            // via the callback because if, in the context of the callback, these messages are
            // requested, they won't be found in the database, causing another remote fetch to
            // occur
            remote_list = yield merge_emails(remote_list, cancellable);
            
            if (accumulator != null && remote_list != null && remote_list.size > 0)
                accumulator.add_all(remote_list);
            
            if (cb != null)
                cb(remote_list, null);
            
            remaining -= list.length;
        }
    }
    
    private async void remote_list_partials(Gee.Collection<Geary.EmailIdentifier> ids,
        Geary.Email.Field remaining_fields) throws Error {
        // possible to call remote multiple times, wait for it to open once and go
        if (!yield engine.wait_for_remote_to_open(cancellable))
            return;
        
        Imap.MessageSet msg_set = new Imap.MessageSet.email_id_collection(ids);
        
        Gee.List<Geary.Email>? remote_list = yield engine.remote_folder.list_email_async(msg_set,
            remaining_fields, cancellable);
        if (remote_list == null || remote_list.size == 0)
            return;
        
        remote_list = yield merge_emails(remote_list, cancellable);
        
        if (accumulator != null && remote_list != null && remote_list.size > 0)
            accumulator.add_all(remote_list);
        
        if (cb != null)
            cb(remote_list, null);
    }
    
    private async Gee.List<Geary.Email> merge_emails(Gee.List<Geary.Email> list,
        Cancellable? cancellable) throws Error {
        NonblockingBatch batch = new NonblockingBatch();
        foreach (Geary.Email email in list)
            batch.add(new CreateLocalEmailOperation(engine.local_folder, email, required_fields));
        
        yield batch.execute_all_async(cancellable);
        
        batch.throw_first_exception();
        
        // report locally added (non-duplicate, not unknown) emails & collect emails post-merge
        Gee.List<Geary.Email> merged_email = new Gee.ArrayList<Geary.Email>();
        Gee.HashSet<Geary.EmailIdentifier> created_ids = new Gee.HashSet<Geary.EmailIdentifier>(
            Hashable.hash_func, Equalable.equal_func);
        foreach (int id in batch.get_ids()) {
            CreateLocalEmailOperation? op = batch.get_operation(id) as CreateLocalEmailOperation;
            if (op != null) {
                if (op.created)
                    created_ids.add(op.email.id);
                
                assert(op.merged != null);
                merged_email.add(op.merged);
            }
        }
        
        if (created_ids.size > 0)
            engine.notify_email_locally_appended(created_ids);
        
        if (cb != null)
            cb(merged_email, null);
        
        return merged_email;
    }
}

private class Geary.ListEmailByID : Geary.ListEmail {
    private Geary.EmailIdentifier initial_id;
    private bool excluding_id;
    
    public ListEmailByID(GenericImapFolder engine, Geary.EmailIdentifier initial_id, int count,
        Geary.Email.Field required_fields, Gee.List<Geary.Email>? accumulator, EmailCallback? cb,
        Cancellable? cancellable, bool local_only, bool remote_only, bool excluding_id) {
        base(engine, 0, count, required_fields, accumulator, cb, cancellable, local_only, remote_only);
        set_name("ListEmailByID");
        
        this.initial_id = initial_id;
        this.excluding_id = excluding_id;
    }
    
    public override async bool replay_local() throws Error {
        Logging.debug(Logging.Flag.OPERATIONS, "ListEmailByID.replay_local: %s initial=%s excl=%s",
            engine.to_string(), initial_id.to_string(), excluding_id.to_string());
        
        int local_count = yield engine.local_folder.get_email_count_async(cancellable);
        
        int initial_position = yield engine.local_folder.get_id_position_async(initial_id, cancellable);
        if (initial_position <= 0) {
            throw new EngineError.NOT_FOUND("Email ID %s in %s not known to local store",
                initial_id.to_string(), engine.to_string());
        }
        
        // normalize the initial position to the remote folder's addressing
        initial_position = engine.local_position_to_remote_position(initial_position, local_count);
        if (initial_position <= 0) {
            throw new EngineError.NOT_FOUND("Cannot map email ID %s in %s to remote folder",
                initial_id.to_string(), engine.to_string());
        }
        
        // since count can also indicate "to earliest" or "to latest", normalize
        // (count is exclusive of initial_id, hence adding/substracting one, meaning that a count
        // of zero or one are accepted)
        int low, high;
        if (count < 0) {
            low = (count != int.MIN) ? (initial_position + count + 1) : 1;
            high = excluding_id ? initial_position - 1 : initial_position;
        } else if (count > 0) {
            low = excluding_id ? initial_position + 1 : initial_position;
            high = (count != int.MAX) ? (initial_position + count - 1) : engine.remote_count;
        } else {
            // count == 0
            low = initial_position;
            high = initial_position;
        }
        
        // low should never be -1, so don't need to check for that
        low = low.clamp(1, int.MAX);
        
        int actual_count = ((high - low) + 1);
        
        // one more check
        if (actual_count == 0) {
            Logging.debug(Logging.Flag.OPERATIONS,
                "ListEmailByID %s: no actual count to return (%d) (excluding=%s %s)",
                engine.to_string(), actual_count, excluding_id.to_string(), initial_id.to_string());
            
            if (cb != null)
                cb(null, null);
            
            return true;
        }
        
        Logging.debug(Logging.Flag.OPERATIONS,
            "ListEmailByID %s: initial_id=%s initial_position=%d count=%d actual_count=%d low=%d high=%d local_count=%d remote_count=%d excl=%s",
            engine.to_string(), initial_id.to_string(), initial_position, count, actual_count, low,
            high, local_count, engine.remote_count, excluding_id.to_string());
        
        this.low = low;
        this.count = actual_count;
        return yield base.replay_local();
    }
}

private class Geary.FetchEmail : Geary.SendReplayOperation {
    public Email? email = null;
    
    private GenericImapFolder engine;
    private EmailIdentifier id;
    private Email.Field required_fields;
    private Email.Field remaining_fields;
    private Folder.ListFlags flags;
    private Cancellable? cancellable;
    
    public FetchEmail(GenericImapFolder engine, EmailIdentifier id, Email.Field required_fields,
        Folder.ListFlags flags, Cancellable? cancellable) {
        base ("FetchEmail");
        
        this.engine = engine;
        this.id = id;
        this.required_fields = required_fields;
        remaining_fields = required_fields;
        this.flags = flags;
        this.cancellable = cancellable;
    }
    
    public override async bool replay_local() throws Error {
        Logging.debug(Logging.Flag.OPERATIONS, "FetchEmail.replay_local %s: %s flags=%Xh required_fields=%Xh",
            engine.to_string(), id.to_string(), flags, required_fields);
        
        // If forcing an update, skip local operation and go direct to replay_remote()
        if (flags.is_all_set(Folder.ListFlags.FORCE_UPDATE))
            return false;
        
        try {
            email = yield engine.local_folder.fetch_email_async(id, required_fields, true,
                cancellable);
        } catch (Error err) {
            // If NOT_FOUND or INCOMPLETE_MESSAGE, then fall through, otherwise return to sender
            if (!(err is Geary.EngineError.NOT_FOUND) && !(err is Geary.EngineError.INCOMPLETE_MESSAGE))
                throw err;
        }
        
        // If returned in full, done
        if (email != null && email.fields.fulfills(required_fields))
            return true;
        
        // If local only and not found fully in local store, throw NOT_FOUND; there is no fallback
        if (flags.is_all_set(Folder.ListFlags.LOCAL_ONLY)) {
            throw new EngineError.NOT_FOUND("Email %s with fields %Xh not found in %s", id.to_string(),
                required_fields, to_string());
        }
        
        // only fetch what's missing
        if (email != null)
            remaining_fields = required_fields.clear(email.fields);
        else
            remaining_fields = required_fields;
        
        assert(remaining_fields != 0);
        
        return false;
    }
    
    public override async bool replay_remote() throws Error {
        Logging.debug(Logging.Flag.OPERATIONS, "FetchEmail.replay_remote %s: %s flags=%Xh required_fields=%Xh remaining_fields=%Xh",
            engine.to_string(), id.to_string(), flags, required_fields, remaining_fields);
        
        if (!yield engine.wait_for_remote_to_open(cancellable))
            throw new EngineError.SERVER_UNAVAILABLE("No connection to %s", engine.to_string());
        
        // fetch only the remaining fields from the remote folder (if only pulling partial information,
        // will merge at end of this method)
        Gee.List<Geary.Email>? list = yield engine.remote_folder.list_email_async(
            new Imap.MessageSet.email_id(id), remaining_fields, cancellable);
        
        if (list == null || list.size != 1)
            throw new EngineError.NOT_FOUND("Unable to fetch %s in %s", id.to_string(), engine.to_string());
        
        // save to local store
        email = list[0];
        assert(email != null);
        if (yield engine.local_folder.create_email_async(email, cancellable))
            engine.notify_email_locally_appended(new Geary.Singleton<Geary.EmailIdentifier>(email.id));
        
        // if remote_email doesn't fulfill all required, pull from local database, which should now
        // be able to do all of that
        if (!email.fields.fulfills(required_fields)) {
            email = yield engine.local_folder.fetch_email_async(id, required_fields, false, cancellable);
            assert(email != null);
        }
        
        return true;
    }
}

