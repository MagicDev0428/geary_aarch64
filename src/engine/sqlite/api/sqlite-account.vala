/* Copyright 2011 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

public class Geary.Sqlite.Account : Geary.AbstractAccount, Geary.LocalAccount {
    private MailDatabase db;
    private FolderTable folder_table;
    private ImapFolderPropertiesTable folder_properties_table;
    private MessageTable message_table;
    
    public Account(Geary.Credentials cred) {
        base ("SQLite account for %s".printf(cred.to_string()));
        
        try {
            db = new MailDatabase(cred.user);
        } catch (Error err) {
            error("Unable to open database: %s", err.message);
        }
        
        folder_table = db.get_folder_table();
        folder_properties_table = db.get_imap_folder_properties_table();
        message_table = db.get_message_table();
    }
    
    public override Geary.Email.Field get_required_fields_for_writing() {
        return Geary.Email.Field.NONE;
    }
    
    private async int64 fetch_id_async(Geary.FolderPath path, Cancellable? cancellable = null)
        throws Error {
        FolderRow? row = yield folder_table.fetch_descend_async(path.as_list(), cancellable);
        if (row == null)
            throw new EngineError.NOT_FOUND("Cannot find local path to %s", path.to_string());
        
        return row.id;
    }
    
    private async int64 fetch_parent_id_async(Geary.FolderPath path, Cancellable? cancellable = null)
        throws Error {
        return path.is_root() ? Row.INVALID_ID : yield fetch_id_async(path.get_parent(), cancellable);
    }
    
    public async void clone_folder_async(Geary.Folder folder, Cancellable? cancellable = null)
        throws Error {
        Geary.Imap.Folder imap_folder = (Geary.Imap.Folder) folder;
        Geary.Imap.FolderProperties? imap_folder_properties = (Geary.Imap.FolderProperties?)
            imap_folder.get_properties();
        
        // properties *must* be available to perform a clone
        assert(imap_folder_properties != null);
        
        int64 parent_id = yield fetch_parent_id_async(folder.get_path(), cancellable);
        
        int64 folder_id = yield folder_table.create_async(new FolderRow(folder_table,
            imap_folder.get_path().basename, parent_id), cancellable);
        
        yield folder_properties_table.create_async(
            new ImapFolderPropertiesRow.from_imap_properties(folder_properties_table, folder_id,
                imap_folder_properties));
    }
    
    public override async Gee.Collection<Geary.Folder> list_folders_async(Geary.FolderPath? parent,
        Cancellable? cancellable = null) throws Error {
        int64 parent_id = (parent != null)
            ? yield fetch_id_async(parent, cancellable)
            : Row.INVALID_ID;
        
        if (parent != null)
            assert(parent_id != Row.INVALID_ID);
        
        Gee.List<FolderRow> rows = yield folder_table.list_async(parent_id, cancellable);
        if (rows.size == 0) {
            throw new EngineError.NOT_FOUND("No local folders in %s",
                (parent != null) ? parent.get_fullpath() : "root");
        }
        
        Gee.Collection<Geary.Folder> folders = new Gee.ArrayList<Geary.Sqlite.Folder>();
        foreach (FolderRow row in rows) {
            ImapFolderPropertiesRow? properties = yield folder_properties_table.fetch_async(row.id,
                cancellable);
            
            Geary.FolderPath path = (parent != null)
                ? parent.get_child(row.name)
                : new Geary.FolderRoot(row.name, "/", Geary.Imap.Folder.CASE_SENSITIVE);
            
            folders.add(new Geary.Sqlite.Folder(db, row, properties, path));
        }
        
        return folders;
    }
    
    public override async bool folder_exists_async(Geary.FolderPath path,
        Cancellable? cancellable = null) throws Error {
        try {
            int64 id = yield fetch_id_async(path, cancellable);
            
            return (id != Row.INVALID_ID);
        } catch (EngineError err) {
            if (err is EngineError.NOT_FOUND)
                return false;
            else
                throw err;
        }
    }
    
    public override async Geary.Folder fetch_folder_async(Geary.FolderPath path,
        Cancellable? cancellable = null) throws Error {
        FolderRow? row =  yield folder_table.fetch_descend_async(path.as_list(), cancellable);
        if (row == null)
            throw new EngineError.NOT_FOUND("%s not found in local database", path.to_string());
        
        ImapFolderPropertiesRow? properties = yield folder_properties_table.fetch_async(row.id,
            cancellable);
        
        return new Geary.Sqlite.Folder(db, row, properties, path);
    }
    
    public async bool has_message_id_async(Geary.RFC822.MessageID message_id, out int count,
        Cancellable? cancellable = null) throws Error {
        count = yield message_table.search_message_id_count_async(message_id);
        
        return (count > 0);
    }
}

