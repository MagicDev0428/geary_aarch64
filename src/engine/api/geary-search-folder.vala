/* Copyright 2011-2013 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution.
 */

public class Geary.SearchFolderRoot : Geary.FolderRoot {
    public const string MAGIC_BASENAME = "$GearySearchFolder$";
    
    public SearchFolderRoot() {
        base(MAGIC_BASENAME, null, false, false);
    }
}

public class Geary.SearchFolderProperties : Geary.FolderProperties {
    public SearchFolderProperties(int total, int unread) {
        base(total, unread, Trillian.FALSE, Trillian.FALSE, Trillian.TRUE);
    }
    
    public void set_total(int total) {
        this.email_total = total;
    }
}

/**
 * Special folder type used to query and display search results.
 */

public class Geary.SearchFolder : Geary.AbstractLocalFolder, Geary.FolderSupport.Remove {
    // Max number of emails that can ever be in the folder.
    public static const int MAX_RESULT_EMAILS = 1000;
    
    private weak Account _account;
    public override Account account { get { return _account; } }
    
    private SearchFolderProperties _properties = new SearchFolderProperties(0, 0);
    public override FolderProperties properties { get { return _properties; } }
    
    private FolderPath? _path = null;
    public override FolderPath path {
        get {
            return (_path != null) ? _path : _path = new SearchFolderRoot();
        }
    }
    
    public override SpecialFolderType special_folder_type {
        get {
            return Geary.SpecialFolderType.SEARCH;
        }
    }
    
    private Gee.HashSet<Geary.FolderPath?> exclude_folders = new Gee.HashSet<Geary.FolderPath?>();
    private Geary.SpecialFolderType[] exclude_types = {
        Geary.SpecialFolderType.SPAM,
        Geary.SpecialFolderType.TRASH,
        // Orphan emails (without a folder) are also excluded; see ctor.
    };
    private string? search_query = null;
    private Gee.TreeSet<ImapDB.SearchEmailIdentifier> search_results;
    private Geary.Nonblocking.Mutex result_mutex = new Geary.Nonblocking.Mutex();
    
    /**
     * Fired when the search query has changed.  This signal is fired *after* the search
     * has completed.
     */
    public signal void search_query_changed(string? query);
    
    public SearchFolder(Account account) {
        _account = account;
        
        account.folders_available_unavailable.connect(on_folders_available_unavailable);
        account.email_locally_complete.connect(on_email_locally_complete);
        account.email_removed.connect(on_account_email_removed);
        
        clear_search_results();
        
        // We always want to exclude emails that don't live anywhere from
        // search results.
        exclude_orphan_emails();
    }
    
    ~SearchFolder() {
        account.folders_available_unavailable.disconnect(on_folders_available_unavailable);
        account.email_locally_complete.disconnect(on_email_locally_complete);
        account.email_removed.disconnect(on_account_email_removed);
    }
    
    private void on_folders_available_unavailable(Gee.Collection<Geary.Folder>? available,
        Gee.Collection<Geary.Folder>? unavailable) {
        if (available != null) {
            foreach (Geary.Folder folder in available) {
                // Exclude it from searching if it's got the right special type.
                if (folder.special_folder_type in exclude_types)
                    exclude_folder(folder);
            }
        }
    }
    
    public override async void find_boundaries_async(Gee.Collection<Geary.EmailIdentifier> ids,
        out Geary.EmailIdentifier? low, out Geary.EmailIdentifier? high,
        Cancellable? cancellable = null) throws Error {
        low = null;
        high = null;
        Gee.TreeSet<ImapDB.SearchEmailIdentifier> in_folder
            = new Gee.TreeSet<ImapDB.SearchEmailIdentifier>();
        foreach (Geary.EmailIdentifier id in ids) {
            ImapDB.SearchEmailIdentifier? search_id = id as ImapDB.SearchEmailIdentifier;
            // This shouldn't require a result_mutex lock since there's no yield.
            if (search_id != null && search_id in search_results)
                in_folder.add(search_id);
        }
        
        if (in_folder.size > 0) {
            low = in_folder.first();
            high = in_folder.last();
        }
    }
    
    private async void append_new_email_async(string query, Geary.Folder folder,
        Gee.Collection<Geary.EmailIdentifier> ids, Cancellable? cancellable) throws Error {
        int result_mutex_token = yield result_mutex.claim_async();
        
        Error? error = null;
        try {
            yield do_search_async(query, ids, cancellable);
        } catch(Error e) {
            error = e;
        }
        
        result_mutex.release(ref result_mutex_token);
        
        if (error != null)
            throw error;
    }
    
    private void on_append_new_email_complete(Object? source, AsyncResult result) {
        try {
            append_new_email_async.end(result);
        } catch(Error e) {
            debug("Error appending new email to search results: %s", e.message);
        }
    }
    
    private void on_email_locally_complete(Geary.Folder folder,
        Gee.Collection<Geary.EmailIdentifier> ids) {
        if (search_query != null)
            append_new_email_async.begin(search_query, folder, ids, null, on_append_new_email_complete);
    }
    
    private async void handle_removed_email_async(string query, Geary.Folder folder,
        Gee.Collection<Geary.EmailIdentifier> ids, Cancellable? cancellable) throws Error {
        int result_mutex_token = yield result_mutex.claim_async();
        
        Error? error = null;
        try {
            Gee.ArrayList<Geary.EmailIdentifier> relevant_ids = new Gee.ArrayList<Geary.EmailIdentifier>();
            foreach (Geary.EmailIdentifier id in ids) {
                if (id in (Gee.Collection<Geary.EmailIdentifier>) search_results)
                    relevant_ids.add(id);
            }
            
            if (relevant_ids.size > 0)
                yield do_search_async(query, relevant_ids, cancellable);
        } catch(Error e) {
            error = e;
        }
        
        result_mutex.release(ref result_mutex_token);
        
        if (error != null)
            throw error;
    }
    
    private void on_handle_removed_email_complete(Object? source, AsyncResult result) {
        try {
            handle_removed_email_async.end(result);
        } catch(Error e) {
            debug("Error removing removed email from search results: %s", e.message);
        }
    }
    
    private void on_account_email_removed(Geary.Folder folder,
        Gee.Collection<Geary.EmailIdentifier> ids) {
        if (search_query != null)
            handle_removed_email_async.begin(search_query, folder, ids, null, on_handle_removed_email_complete);
    }
    
    /**
     * Clears the search query and results.
     */
    public void clear() {
        Gee.Collection<ImapDB.SearchEmailIdentifier> local_results = search_results;
        clear_search_results();
        notify_email_removed(local_results);
        notify_email_count_changed(0, Geary.Folder.CountChangeReason.REMOVED);
        
        if (search_query != null) {
            search_query = null;
            search_query_changed(null);
        }
    }
    
    /**
     * Sets the keyword string for this search.
     */
    public void set_search_query(string query, Cancellable? cancellable = null) {
        set_search_query_async.begin(query, cancellable, on_set_search_query_complete);
    }
    
    private void on_set_search_query_complete(Object? source, AsyncResult result) {
        try {
            set_search_query_async.end(result);
        } catch(Error e) {
            debug("Search error: %s", e.message);
        }
    }
    
    private async void set_search_query_async(string query, Cancellable? cancellable = null) throws Error {
        int result_mutex_token = yield result_mutex.claim_async();
        
        Error? error = null;
        try {
            yield do_search_async(query, null, cancellable);
        } catch(Error e) {
            error = e;
        }
        
        result_mutex.release(ref result_mutex_token);
        
        search_query = query;
        search_query_changed(query);
        
        if (error != null)
            throw error;
    }
    
    // NOTE: you must call this ONLY after locking result_mutex_token.
    // If search_ids is null, the results of this search are considered to be
    // the full new set.  If non-null, the results are considered to be a delta
    // and are added or subtracted from the full set.
    private async void do_search_async(string query, Gee.Collection<Geary.EmailIdentifier>? search_ids,
        Cancellable? cancellable) throws Error {
        // TODO: don't limit this to MAX_RESULT_EMAILS.  Instead, we could be
        // smarter about only fetching the search results in list_email_async()
        // etc., but this leads to some more complications when redoing the
        // search.
        Gee.ArrayList<ImapDB.SearchEmailIdentifier> results
            = ImapDB.SearchEmailIdentifier.array_list_from_results(yield account.local_search_async(
            query, MAX_RESULT_EMAILS, 0, exclude_folders, search_ids, cancellable));
        
        Gee.ArrayList<ImapDB.SearchEmailIdentifier> added
            = new Gee.ArrayList<ImapDB.SearchEmailIdentifier>();
        Gee.ArrayList<Geary.EmailIdentifier> removed
            = new Gee.ArrayList<ImapDB.SearchEmailIdentifier>();
        
        Gee.Collection<Geary.EmailIdentifier> potentially_removed_ids
            = (search_ids == null ? search_results : search_ids);
        
        foreach (ImapDB.SearchEmailIdentifier id in results) {
            if (!(id in search_results))
                added.add(id);
        }
        foreach (Geary.EmailIdentifier id in potentially_removed_ids) {
            if (!(id in (Gee.Collection<Geary.EmailIdentifier>) results))
                removed.add(id);
        }
        
        bool first_results = search_results.size == 0;
        
        search_results.remove_all(removed);
        search_results.add_all(added);
        
        _properties.set_total(search_results.size);
        
        // Note that we probably shouldn't be firing these signals from inside
        // our mutex lock.  Keep an eye on it, and if there's ever a case where
        // it might cause problems, it shouldn't be too hard to move the
        // firings outside.
        
        Geary.Folder.CountChangeReason reason = CountChangeReason.NONE;
        if (added.size > 0) {
            // We do a little optimization here.  In the case we can trivially
            // determine nothing was added "in the middle" of an existing
            // result set, we say the results were appended rather than
            // inserted because appends are handled more gracefully in the
            // conversation monitor.
            reason |= (first_results ? Geary.Folder.CountChangeReason.APPENDED
                : Geary.Folder.CountChangeReason.INSERTED);
        }
        if (removed.size > 0) {
            notify_email_removed(removed);
            reason |= Geary.Folder.CountChangeReason.REMOVED;
        }
        if (reason != CountChangeReason.NONE)
            notify_email_count_changed(search_results.size, reason);
    }
    
    public override async Gee.List<Geary.Email>? list_email_by_id_async(Geary.EmailIdentifier? initial_id,
        int count, Geary.Email.Field required_fields, Folder.ListFlags flags, Cancellable? cancellable = null)
        throws Error {
        if (count <= 0)
            return null;
        
        // TODO: as above, this is incomplete and inefficient.
        int result_mutex_token = yield result_mutex.claim_async();
        
        Geary.EmailIdentifier[] ids = new Geary.EmailIdentifier[search_results.size];
        int initial_index = 0;
        int i = 0;
        foreach (ImapDB.SearchEmailIdentifier id in search_results) {
            if (initial_id != null && id.equal_to(initial_id))
                initial_index = i;
            ids[i++] = id;
        }
        
        if (initial_id == null && flags.is_all_set(Folder.ListFlags.OLDEST_TO_NEWEST))
            initial_index = ids.length - 1;
        
        Gee.List<Geary.Email> results = new Gee.ArrayList<Geary.Email>();
        Error? fetch_err = null;
        if (initial_index >= 0) {
            int increment = flags.is_oldest_to_newest() ? -1 : 1;
            i = initial_index;
            if (!flags.is_including_id() && initial_id != null)
                i += increment;
            int end = i + (count * increment);
            
            for (; i >= 0 && i < search_results.size && i != end; i += increment) {
                try {
                    results.add(yield fetch_email_async(ids[i], required_fields, flags, cancellable));
                } catch (Error err) {
                    // Don't let missing or incomplete messages stop the list operation, which has
                    // different symantics from fetch
                    if (!(err is EngineError.NOT_FOUND) && !(err is EngineError.INCOMPLETE_MESSAGE)) {
                        fetch_err = err;
                        
                        break;
                    }
                }
            }
        }
        
        result_mutex.release(ref result_mutex_token);
        
        if (fetch_err != null)
            throw fetch_err;
        
        return (results.size == 0 ? null : results);
    }
    
    public override async Gee.List<Geary.Email>? list_email_by_sparse_id_async(
        Gee.Collection<Geary.EmailIdentifier> ids, Geary.Email.Field required_fields, Folder.ListFlags flags,
        Cancellable? cancellable = null) throws Error {
        // TODO: Fetch emails in a batch.
        Gee.List<Geary.Email> result = new Gee.ArrayList<Geary.Email>();
        foreach(Geary.EmailIdentifier id in ids)
            result.add(yield fetch_email_async(id, required_fields, flags, cancellable));
        
        return (result.size == 0 ? null : result);
    }
    
    public override async Gee.Map<Geary.EmailIdentifier, Geary.Email.Field>? list_local_email_fields_async(
        Gee.Collection<Geary.EmailIdentifier> ids, Cancellable? cancellable = null) throws Error {
        // TODO: This method is not currently called, but is required by the interface.  Before completing
        // this feature, it should either be implemented either here or in AbstractLocalFolder. 
        error("Search folder does not implement list_local_email_fields_async");
    }
    
    public override async Geary.Email fetch_email_async(Geary.EmailIdentifier id,
        Geary.Email.Field required_fields, Geary.Folder.ListFlags flags,
        Cancellable? cancellable = null) throws Error {
        return yield account.local_fetch_email_async(id, required_fields, cancellable);
    }
    
    public virtual async void remove_email_async(Gee.List<Geary.EmailIdentifier> email_ids,
        Cancellable? cancellable = null) throws Error {
        Gee.MultiMap<Geary.EmailIdentifier, Geary.FolderPath>? ids_to_folders
            = yield account.get_containing_folders_async(email_ids, cancellable);
        if (ids_to_folders == null)
            return;
        
        Gee.MultiMap<Geary.FolderPath, Geary.EmailIdentifier> folders_to_ids
            = Geary.Collection.reverse_multi_map<Geary.EmailIdentifier, Geary.FolderPath>(ids_to_folders);
        
        foreach (Geary.FolderPath path in folders_to_ids.get_keys()) {
            Geary.Folder folder = yield account.fetch_folder_async(path, cancellable);
            Geary.FolderSupport.Remove? remove = folder as Geary.FolderSupport.Remove;
            if (remove == null)
                continue;
            
            Gee.Collection<Geary.EmailIdentifier> ids = folders_to_ids.get(path);
            assert(ids.size > 0);
            
            debug("Search folder removing %d emails from %s", ids.size, folder.to_string());
            
            bool open = false;
            try {
                yield folder.open_async(Geary.Folder.OpenFlags.FAST_OPEN, cancellable);
                open = true;
                
                yield remove.remove_email_async(
                    Geary.Collection.to_array_list<Geary.EmailIdentifier>(ids), cancellable);
                
                yield folder.close_async(cancellable);
                open = false;
            } catch (Error e) {
                debug("Error removing messages in %s: %s", folder.to_string(), e.message);
                
                if (open) {
                    try {
                        yield folder.close_async(cancellable);
                        open = false;
                    } catch (Error e) {
                        debug("Error closing folder %s: %s", folder.to_string(), e.message);
                    }
                }
            }
        }
    }
    
    /**
     * Given a list of mail IDs, returns a list of words that match for the current
     * search query.
     */
    public async Gee.Collection<string>? get_search_matches_async(
        Gee.Collection<Geary.EmailIdentifier> ids, Cancellable? cancellable = null) throws Error {
        if (search_query == null)
            return null;
        return yield account.get_search_matches_async(ids, cancellable);
    }
    
    private void exclude_folder(Geary.Folder folder) {
        exclude_folders.add(folder.path);
    }
    
    private void exclude_orphan_emails() {
        exclude_folders.add(null);
    }
    
    private void clear_search_results() {
        search_results = new Gee.TreeSet<ImapDB.SearchEmailIdentifier>(
            ImapDB.SearchEmailIdentifier.compare_descending);
    }
}

