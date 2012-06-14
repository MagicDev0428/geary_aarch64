/* Copyright 2011-2012 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

private abstract class Geary.GenericImapAccount : Geary.EngineAccount {
    private Imap.Account remote;
    private Sqlite.Account local;
    private Gee.HashMap<FolderPath, Imap.FolderProperties> properties_map = new Gee.HashMap<
        FolderPath, Imap.FolderProperties>(Hashable.hash_func, Equalable.equal_func);
    private SmtpOutboxFolder? outbox = null;
    private Gee.HashMap<FolderPath, GenericImapFolder> existing_folders = new Gee.HashMap<
        FolderPath, GenericImapFolder>(Hashable.hash_func, Equalable.equal_func);
    
    public GenericImapAccount(string name, string username, AccountInformation? account_info,
        File user_data_dir, Imap.Account remote, Sqlite.Account local) {
        base (name, username, account_info, user_data_dir);
        
        this.remote = remote;
        this.local = local;
        
        this.remote.login_failed.connect(on_login_failed);
    }
    
    internal Imap.FolderProperties? get_properties_for_folder(FolderPath path) {
        return properties_map.get(path);
    }
    
    public override async void open_async(Cancellable? cancellable = null) throws Error {
        yield local.open_async(get_account_information().credentials, Engine.user_data_dir, Engine.resource_dir,
            cancellable);
        
        // need to back out local.open_async() if remote fails
        try {
            yield remote.open_async(cancellable);
        } catch (Error err) {
            // back out
            try {
                yield local.close_async(cancellable);
            } catch (Error close_err) {
                // ignored
            }
            
            throw err;
        }
        
        outbox = new SmtpOutboxFolder(remote, local.get_outbox());
        
        notify_opened();
    }
    
    public override async void close_async(Cancellable? cancellable = null) throws Error {
        // attempt to close both regardless of errors
        Error? local_err = null;
        try {
            yield local.close_async(cancellable);
        } catch (Error lclose_err) {
            local_err = lclose_err;
        }
        
        Error? remote_err = null;
        try {
            yield remote.close_async(cancellable);
        } catch (Error rclose_err) {
            remote_err = rclose_err;
        }
        
        outbox = null;
        
        if (local_err != null)
            throw local_err;
        
        if (remote_err != null)
            throw remote_err;
    }
    
    private GenericImapFolder build_folder(Sqlite.Folder local_folder) {
        GenericImapFolder? folder = existing_folders.get(local_folder.get_path());
        if (folder != null)
            return folder;
        
        folder = new GenericImapFolder(this, remote, local, local_folder,
            get_special_folder(local_folder.get_path()));
        existing_folders.set(folder.get_path(), folder);
        
        return folder;
    }
    
    public override async Gee.Collection<Geary.Folder> list_folders_async(Geary.FolderPath? parent,
        Cancellable? cancellable = null) throws Error {
        Gee.Collection<Geary.Sqlite.Folder>? local_list = null;
        try {
            local_list = yield local.list_folders_async(parent, cancellable);
        } catch (EngineError err) {
            // don't pass on NOT_FOUND's, that means we need to go to the server for more info
            if (!(err is EngineError.NOT_FOUND))
                throw err;
        }
        
        Gee.Collection<Geary.Folder> engine_list = new Gee.ArrayList<Geary.Folder>();
        if (local_list != null && local_list.size > 0) {
            foreach (Geary.Sqlite.Folder local_folder in local_list)
                engine_list.add(build_folder(local_folder));
        }
        
        background_update_folders.begin(parent, engine_list, cancellable);
        engine_list.add(outbox);
        
        return engine_list;
    }
    
    public override async bool folder_exists_async(Geary.FolderPath path,
        Cancellable? cancellable = null) throws Error {
        if (yield local.folder_exists_async(path, cancellable))
            return true;
        
        return yield remote.folder_exists_async(path, cancellable);
    }
    
    public override async Geary.Folder fetch_folder_async(Geary.FolderPath path,
        Cancellable? cancellable = null) throws Error {
        
        if (path.equals(outbox.get_path()))
            return outbox;
        
        try {
            return build_folder((Sqlite.Folder) yield local.fetch_folder_async(path, cancellable));
        } catch (EngineError err) {
            // don't thrown NOT_FOUND's, that means we need to fall through and clone from the
            // server
            if (!(err is EngineError.NOT_FOUND))
                throw err;
        }
        
        // clone the entire path
        int length = path.get_path_length();
        for (int ctr = 0; ctr < length; ctr++) {
            Geary.FolderPath folder = path.get_folder_at(ctr);
            
            if (yield local.folder_exists_async(folder))
                continue;
            
            Imap.Folder remote_folder = (Imap.Folder) yield remote.fetch_folder_async(folder,
                cancellable);
            
            yield local.clone_folder_async(remote_folder, cancellable);
        }
        
        // Fetch the local account's version of the folder for the GenericImapFolder
        return build_folder((Sqlite.Folder) yield local.fetch_folder_async(path, cancellable));
    }
    
    private async void background_update_folders(Geary.FolderPath? parent,
        Gee.Collection<Geary.Folder> engine_folders, Cancellable? cancellable) {
        Gee.Collection<Geary.Imap.Folder> remote_folders;
        try {
            remote_folders = yield remote.list_folders_async(parent, cancellable);
        } catch (Error remote_error) {
            debug("Unable to retrieve folder list from server: %s", remote_error.message);
            
            return;
        }
        
        Gee.Set<string> local_names = new Gee.HashSet<string>();
        foreach (Geary.Folder folder in engine_folders)
            local_names.add(folder.get_path().basename);
        
        Gee.Set<string> remote_names = new Gee.HashSet<string>();
        foreach (Geary.Imap.Folder folder in remote_folders) {
            remote_names.add(folder.get_path().basename);
            
            // use this iteration to add discovered properties to map
            properties_map.set(folder.get_path(), folder.get_properties());
        }
        
        Gee.List<Geary.Imap.Folder> to_add = new Gee.ArrayList<Geary.Imap.Folder>();
        foreach (Geary.Imap.Folder folder in remote_folders) {
            if (!local_names.contains(folder.get_path().basename))
                to_add.add(folder);
        }
        
        Gee.List<Geary.Folder>? to_remove = new Gee.ArrayList<Geary.Imap.Folder>();
        foreach (Geary.Folder folder in engine_folders) {
            if (!remote_names.contains(folder.get_path().basename))
                to_remove.add(folder);
        }
        
        if (to_add.size == 0)
            to_add = null;
        
        if (to_remove.size == 0)
            to_remove = null;
        
        if (to_add != null) {
            foreach (Geary.Imap.Folder folder in to_add) {
                try {
                    yield local.clone_folder_async(folder, cancellable);
                } catch (Error err) {
                    debug("Unable to add/remove folder %s: %s", folder.get_path().to_string(),
                        err.message);
                }
            }
        }
        
        Gee.Collection<Geary.Folder> engine_added = null;
        if (to_add != null) {
            engine_added = new Gee.ArrayList<Geary.Folder>();
            foreach (Geary.Imap.Folder remote_folder in to_add) {
                try {
                    engine_added.add(build_folder((Sqlite.Folder) yield local.fetch_folder_async(
                        remote_folder.get_path(), cancellable)));
                } catch (Error convert_err) {
                    error("Unable to fetch local folder: %s", convert_err.message);
                }
            }
        }
        
        if (engine_added != null)
            notify_folders_added_removed(engine_added, null);
    }
    
    public override string get_user_folders_label() {
        return _("Folders");
    }
    
    public override Gee.Set<Geary.FolderPath>? get_ignored_paths() {
        return null;
    }
    
    public override bool delete_is_archive() {
        return false;
    }
    
    public override async void send_email_async(Geary.ComposedEmail composed,
        Cancellable? cancellable = null) throws Error {
        Geary.RFC822.Message rfc822 = new Geary.RFC822.Message.from_composed_email(composed);
        yield outbox.create_email_async(rfc822, cancellable);
    }
    
    private void on_login_failed(Geary.Credentials? credentials) {
        notify_report_problem(Geary.Account.Problem.LOGIN_FAILED, credentials, null);
    }
    
    private SpecialFolder? get_special_folder(FolderPath path) {
        if (get_special_folder_map() != null) {
            return get_special_folder_map().get_folder_by_path(path);
        }
        return null;
    }
}

