/* Copyright 2012 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

private class Geary.ImapEngine.ListEmailBySparseID : Geary.ImapEngine.SendReplayOperation {
    private class LocalBatchOperation : NonblockingBatchOperation {
        public GenericFolder owner;
        public Geary.EmailIdentifier id;
        public Geary.Email.Field required_fields;
        
        public LocalBatchOperation(GenericFolder owner, Geary.EmailIdentifier id,
            Geary.Email.Field required_fields) {
            this.owner = owner;
            this.id = id;
            this.required_fields = required_fields;
        }
        
        public override async Object? execute_async(Cancellable? cancellable) throws Error {
            try {
                return yield owner.local_folder.fetch_email_async(id, required_fields,
                    ImapDB.Folder.ListFlags.PARTIAL_OK, cancellable);
            } catch (Error err) {
                // only throw errors that are not NOT_FOUND and INCOMPLETE_MESSAGE, as these two
                // are recoverable
                if (!(err is Geary.EngineError.NOT_FOUND) && !(err is Geary.EngineError.INCOMPLETE_MESSAGE))
                    throw err;
            }
            
            return null;
        }
    }
    
    private class RemoteBatchOperation : NonblockingBatchOperation {
        public GenericFolder owner;
        public Imap.MessageSet msg_set;
        public Geary.Email.Field unfulfilled_fields;
        public Geary.Email.Field required_fields;
        
        public RemoteBatchOperation(GenericFolder owner, Imap.MessageSet msg_set,
            Geary.Email.Field unfulfilled_fields, Geary.Email.Field required_fields) {
            this.owner = owner;
            this.msg_set = msg_set;
            this.unfulfilled_fields = unfulfilled_fields;
            this.required_fields = required_fields;
        }
        
        public override async Object? execute_async(Cancellable? cancellable) throws Error {
            yield owner.throw_if_remote_not_ready_async(cancellable);
            
            // fetch from remote folder
            Gee.List<Geary.Email>? list = yield owner.remote_folder.list_email_async(msg_set,
                unfulfilled_fields, cancellable);
            if (list == null || list.size == 0)
                return null;
            
            // create all locally and merge results if required
            for (int ctr = 0; ctr < list.size; ctr++) {
                Geary.Email email = list[ctr];
                
                yield owner.local_folder.create_or_merge_email_async(email, cancellable);
                
                // if remote email doesn't fulfills all required fields, fetch full and return that
                if (!email.fields.fulfills(required_fields)) {
                    email = yield owner.local_folder.fetch_email_async(email.id, required_fields,
                        ImapDB.Folder.ListFlags.NONE, cancellable);
                    list[ctr] = email;
                }
            }
            
            return list;
        }
    }
    
    private GenericFolder owner;
    private Gee.HashSet<Geary.EmailIdentifier> ids = new Gee.HashSet<Geary.EmailIdentifier>(
        Hashable.hash_func, Equalable.equal_func);
    private Geary.Email.Field required_fields;
    private Folder.ListFlags flags;
    private bool local_only;
    private bool force_update;
    private Gee.Collection<Geary.Email>? accumulator;
    private unowned EmailCallback cb;
    private Cancellable? cancellable;
    private Gee.HashMultiMap<Geary.Email.Field, Geary.EmailIdentifier> unfulfilled = new Gee.HashMultiMap<
        Geary.Email.Field, Geary.EmailIdentifier>(null, null, Hashable.hash_func, Equalable.equal_func);
    
    public ListEmailBySparseID(GenericFolder owner, Gee.Collection<Geary.EmailIdentifier> ids,
        Geary.Email.Field required_fields, Folder.ListFlags flags, Gee.List<Geary.Email>? accumulator,
        EmailCallback cb, Cancellable? cancellable) {
        base ("ListEmailBySparseID");
        
        this.owner = owner;
        this.ids.add_all(ids);
        this.required_fields = required_fields;
        this.flags = flags;
        this.accumulator = accumulator;
        this.cb = cb;
        this.cancellable = cancellable;
        
        local_only = flags.is_all_set(Folder.ListFlags.LOCAL_ONLY);
        force_update = flags.is_all_set(Folder.ListFlags.FORCE_UPDATE);
    }
    
    public override async ReplayOperation.Status replay_local_async() throws Error {
        if (force_update) {
            foreach (EmailIdentifier id in ids)
                unfulfilled.set(required_fields, id);
            
            return ReplayOperation.Status.CONTINUE;
        }
        
        NonblockingBatch batch = new NonblockingBatch();
        
        // Fetch emails by ID from local store all at once
        foreach (Geary.EmailIdentifier id in ids)
            batch.add(new LocalBatchOperation(owner, id, required_fields));
        
        yield batch.execute_all_async(cancellable);
        batch.throw_first_exception();
        
        // Build list of emails fully fetched from local store and table of remaining emails by
        // their lack of completeness
        Gee.List<Geary.Email> fulfilled = new Gee.ArrayList<Geary.Email>();
        foreach (int batch_id in batch.get_ids()) {
            LocalBatchOperation local_op = (LocalBatchOperation) batch.get_operation(batch_id);
            Geary.Email? email = (Geary.Email?) batch.get_result(batch_id);
            
            if (email == null)
                unfulfilled.set(required_fields, local_op.id);
            else if (!email.fields.fulfills(required_fields))
                unfulfilled.set(required_fields.clear(email.fields), local_op.id);
            else
                fulfilled.add(email);
        }
        
        if (fulfilled.size > 0) {
            if (accumulator != null)
                accumulator.add_all(fulfilled);
            
            if (cb != null)
                cb(fulfilled, null);
        }
        
        if (local_only || unfulfilled.size == 0) {
            if (cb != null)
                cb(null, null);
            
            return ReplayOperation.Status.COMPLETED;
        }
        
        return ReplayOperation.Status.CONTINUE;
    }
    
    public override async ReplayOperation.Status replay_remote_async() throws Error {
        yield owner.throw_if_remote_not_ready_async(cancellable);
        
        NonblockingBatch batch = new NonblockingBatch();
        
        // schedule operations to remote for each set of email with unfulfilled fields and merge
        // in results, pulling out the entire email
        foreach (Geary.Email.Field unfulfilled_fields in unfulfilled.get_keys()) {
            Imap.MessageSet msg_set = new Imap.MessageSet.email_id_collection(
                unfulfilled.get(unfulfilled_fields));
            RemoteBatchOperation remote_op = new RemoteBatchOperation(owner, msg_set, unfulfilled_fields,
                required_fields);
            batch.add(remote_op);
        }
        
        yield batch.execute_all_async(cancellable);
        batch.throw_first_exception();
        
        Gee.ArrayList<Geary.Email> result_list = new Gee.ArrayList<Geary.Email>();
        foreach (int batch_id in batch.get_ids()) {
            Gee.List<Geary.Email>? list = (Gee.List<Geary.Email>?) batch.get_result(batch_id);
            if (list != null && list.size > 0)
                result_list.add_all(list);
        }
        
        // report merged emails
        if (result_list.size > 0) {
            if (accumulator != null)
                accumulator.add_all(result_list);
            
            if (cb != null)
                cb(result_list, null);
        }
        
        // done
        if (cb != null)
            cb(null, null);
        
        return ReplayOperation.Status.COMPLETED;
    }
    
    public override async void backout_local_async() throws Error {
        // R/O, nothing to backout
    }
    
    public override string describe_state() {
        return "ids.size=%d required_fields=%Xh flags=%Xh".printf(ids.size, required_fields, flags);
    }
}

