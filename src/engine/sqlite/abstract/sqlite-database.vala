/* Copyright 2011-2012 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

public abstract class Geary.Sqlite.Database {
    internal SQLHeavy.VersionedDatabase db;
    
    private Gee.HashMap<SQLHeavy.Table, Geary.Sqlite.Table> table_map = new Gee.HashMap<
        SQLHeavy.Table, Geary.Sqlite.Table>();
    
    public Database(File db_file, File schema_dir) throws Error {
        if (!db_file.get_parent().query_exists())
            db_file.get_parent().make_directory_with_parents();
        
        db = new SQLHeavy.VersionedDatabase(db_file.get_path(), schema_dir.get_path());
        db.foreign_keys = true;
        db.synchronous = SQLHeavy.SynchronousMode.OFF;
    }
    
    protected Geary.Sqlite.Table? get_table(string name, out SQLHeavy.Table heavy_table) {
        try {
            heavy_table = db.get_table(name);
        } catch (SQLHeavy.Error err) {
            error("Unable to load %s: %s", name, err.message);
        }
        
        return table_map.get(heavy_table);
    }
    
    protected Geary.Sqlite.Table add_table(Geary.Sqlite.Table table) {
        table_map.set(table.table, table);
        
        return table;
    }
    
    public async Transaction begin_transaction_async(string name, Cancellable? cancellable) throws Error {
        Transaction t = new Transaction(db, name);
        yield t.begin_async(cancellable);
        
        return t;
    }
}

