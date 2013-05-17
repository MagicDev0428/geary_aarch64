/* Copyright 2012-2013 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution.
 */

extern int sqlite3_unicodesn_register_tokenizer(Sqlite.Database db);

private class Geary.ImapDB.Database : Geary.Db.VersionedDatabase {
    private const string DB_FILENAME = "geary.db";
    private string account_owner_email;
    
    public Database(File db_dir, File schema_dir, string account_owner_email) {
        base (db_dir.get_child(DB_FILENAME), schema_dir);
        this.account_owner_email = account_owner_email;
    }
    
    public override void open(Db.DatabaseFlags flags, Db.PrepareConnection? prepare_cb,
        Cancellable? cancellable = null) throws Error {
        // have to do it this way because delegates don't play well with the ternary or nullable
        // operators
        if (prepare_cb != null)
            base.open(flags, prepare_cb, cancellable);
        else
            base.open(flags, on_prepare_database_connection, cancellable);
    }
    
    protected override void post_upgrade(int version) {
        switch (version) {
            case 5:
                post_upgrade_populate_autocomplete();
            break;
            
            case 6:
                post_upgrade_encode_folder_names();
            break;
            
            case 10:
                post_upgrade_add_search_table();
            break;
        }
    }
    
    // Version 5.
    private void post_upgrade_populate_autocomplete() {
        try {
            Db.Result result = query("SELECT sender, from_field, to_field, cc, bcc FROM MessageTable");
            while (!result.finished) {
                MessageAddresses message_addresses =
                    new MessageAddresses.from_result(account_owner_email, result);
                foreach (Contact contact in message_addresses.contacts)
                    do_update_contact(get_master_connection(), contact, null);
                result.next();
            }
        } catch (Error err) {
            debug("Error populating autocompletion table during upgrade to database schema 5");
        }
    }
    
    // Version 6.
    private void post_upgrade_encode_folder_names() {
        try {
            Db.Result select = query("SELECT id, name FROM FolderTable");
            while (!select.finished) {
                int64 id = select.int64_at(0);
                string encoded_name = select.string_at(1);
                
                try {
                    string canonical_name = Geary.ImapUtf7.imap_utf7_to_utf8(encoded_name);
                    
                    Db.Statement update = prepare("UPDATE FolderTable SET name=? WHERE id=?");
                    update.bind_string(0, canonical_name);
                    update.bind_int64(1, id);
                    update.exec();
                } catch (Error e) {
                    debug("Error renaming folder %s to its canonical representation: %s", encoded_name, e.message);
                }
                
                select.next();
            }
        } catch (Error e) {
            debug("Error decoding folder names during upgrade to database schema 6: %s", e.message);
        }
    }
    
    // Version 10.
    private void post_upgrade_add_search_table() {
        try {
            // This can't go in the .sql file because its schema (the stemmer
            // algorithm) is determined at runtime.
            string stemmer = "english"; // TODO
            exec("""
                CREATE VIRTUAL TABLE MessageSearchTable USING fts4(
                    id INTEGER PRIMARY KEY,
                    body,
                    attachment,
                    subject,
                    from_field,
                    receivers,
                    cc,
                    bcc,
                    
                    tokenize=unicodesn "stemmer=%s",
                    prefix="2,4,6,8,10",
                );
            """.printf(stemmer));
        } catch (Error e) {
            error("Error creating search table: %s", e.message);
        }
        
        bool done = false;
        int limit = 100;
        for (int offset = 0; !done; offset += limit) {
            try {
                exec_transaction(Db.TransactionType.RW, (cx) => {
                    Db.Statement stmt = prepare(
                        "SELECT id FROM MessageTable ORDER BY id LIMIT ? OFFSET ?");
                    stmt.bind_int(0, limit);
                    stmt.bind_int(1, offset);
                    
                    Db.Result result = stmt.exec();
                    if (result.finished)
                        done = true;
                    
                    while (!result.finished) {
                        int64 id = result.rowid_at(0);
                        
                        try {
                            MessageRow row = Geary.ImapDB.Folder.do_fetch_message_row(
                                cx, id, Geary.ImapDB.Folder.REQUIRED_FOR_SEARCH, null);
                            Geary.Email email = row.to_email(-1, new Geary.ImapDB.EmailIdentifier(id));
                            Geary.ImapDB.Folder.do_add_attachments(cx, email, id);
                            
                            Geary.ImapDB.Folder.do_add_email_to_search_table(cx, id, email, null);
                        } catch (Error e) {
                            debug("Error adding message %lld to the search table: %s", id, e.message);
                        }
                        
                        result.next();
                    }
                    
                    return Db.TransactionOutcome.DONE;
                });
            } catch (Error e) {
                debug("Error populating search table: %s", e.message);
            }
        }
    }
    
    private void on_prepare_database_connection(Db.Connection cx) throws Error {
        cx.set_busy_timeout_msec(Db.Connection.RECOMMENDED_BUSY_TIMEOUT_MSEC);
        cx.set_foreign_keys(true);
        cx.set_recursive_triggers(true);
        cx.set_synchronous(Db.SynchronousMode.OFF);
        sqlite3_unicodesn_register_tokenizer(cx.db);
    }
}

