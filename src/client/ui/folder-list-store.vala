/* Copyright 2011-2012 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

// These are defined here due to this bug:
// https://bugzilla.gnome.org/show_bug.cgi?id=653379
public enum TreeSortable {
    DEFAULT_SORT_COLUMN_ID = -1,
    UNSORTED_SORT_COLUMN_ID = -2
}

public class FolderListStore : Gtk.TreeStore {
    private enum Internal {
        SPECIAL_FOLDER,
        USER_FOLDER_ROOT,
        USER_FOLDER
    }
    
    public enum Column {
        NAME,
        FOLDER_OBJECT,
        INTERNAL,
        ORDERING,
        N_COLUMNS;
        
        public static Column[] all() {
            return {
                NAME,
                FOLDER_OBJECT
            };
        }
        
        public static Type[] get_types() {
            return {
                typeof (string),
                typeof (Geary.Folder),
                typeof (Internal),
                typeof (int)
            };
        }
        
        public string to_string() {
            switch (this) {
                case NAME:
                    return _("Name");
                
                default:
                    return "(hidden)";
            }
        }
    }
    
    public FolderListStore() {
        set_column_types(Column.get_types());
        set_default_sort_func(sort_by_name);
        set_sort_column_id(TreeSortable.DEFAULT_SORT_COLUMN_ID, Gtk.SortType.ASCENDING);
        
        // add user folder root
        Gtk.TreeIter iter;
        append(out iter, null);
        
        set(iter,
            Column.NAME, _("Folders"),
            Column.INTERNAL, Internal.USER_FOLDER_ROOT
        );
    }
    
    public void set_user_folders_root_name(string name) {
        Gtk.TreeIter? iter = get_user_folders_iter();
        if (iter == null)
            return;
        
        set(iter,
            Column.NAME, name
        );
    }
    
    public void add_special_folder(Geary.SpecialFolder special, Geary.Folder folder) {
        Gtk.TreeIter iter;
        append(out iter, null);
        
        set(iter,
            Column.NAME, special.name,
            Column.FOLDER_OBJECT, folder,
            Column.INTERNAL, Internal.SPECIAL_FOLDER,
            Column.ORDERING, special.ordering
        );
    }
    
    public void add_user_folder(Geary.Folder folder) {
        Gtk.TreeIter? user_folders_root_iter = get_user_folders_iter();
        if (user_folders_root_iter == null)
            return;
        
        Gtk.TreeIter? parent_iter = !folder.get_path().is_root()
            ? find_path(folder.get_path().get_parent(), user_folders_root_iter)
            : user_folders_root_iter;
        
        Gtk.TreeIter iter;
        append(out iter, parent_iter);
        
        set(iter,
            Column.NAME, folder.get_path().basename,
            Column.FOLDER_OBJECT, folder,
            Column.INTERNAL, Internal.USER_FOLDER
        );
    }
    
    public Geary.Folder? get_folder_at(Gtk.TreePath path) {
        Gtk.TreeIter iter;
        if (!get_iter(out iter, path))
            return null;
        
        Geary.Folder folder;
        get(iter, Column.FOLDER_OBJECT, out folder);
        
        return folder;
    }
    
    private Gtk.TreeIter? get_user_folders_iter() {
        Gtk.TreeIter iter;
        get_iter_first(out iter);
        
        do {
            Internal internl;
            get(iter, Column.INTERNAL, out internl);
            
            if (internl == Internal.USER_FOLDER_ROOT)
                return iter;
        } while (iter_next(ref iter));
        
        debug("Unable to locate user folders root");
        
        return null;
    }
    
    // TODO: This could be replaced with a binary search
    public Gtk.TreeIter? find_path(Geary.FolderPath path, Gtk.TreeIter? parent = null) {
        Gtk.TreeIter iter;
        // no parent, start at the root, otherwise start at the parent's children
        if (parent == null) {
            if (!get_iter_first(out iter))
                return null;
        } else {
            if (!iter_children(out iter, parent))
                return null;
        }
        
        do {
            Geary.Folder folder;
            get(iter, Column.FOLDER_OBJECT, out folder);
            
            if (folder.get_path().equals(path))
                return iter;
            
            // recurse
            if (iter_has_child(iter)) {
                Gtk.TreeIter? found = find_path(path, iter);
                if (found != null)
                    return found;
            }
        } while (iter_next(ref iter));
        
        return null;
    }
    
    private int sort_by_name(Gtk.TreeModel model, Gtk.TreeIter aiter, Gtk.TreeIter biter) {
        Internal ainternal;
        model.get(aiter, Column.INTERNAL, out ainternal);
        
        Internal binternal;
        model.get(biter, Column.INTERNAL, out binternal);
        
        // sort special folders in their own magical way
        if (ainternal == Internal.SPECIAL_FOLDER && binternal == Internal.SPECIAL_FOLDER) {
            int apos;
            model.get(aiter, Column.ORDERING, out apos);
            
            int bpos;
            model.get(biter, Column.ORDERING, out bpos);
            
            return apos - bpos;
        }
        
        // sort the USER_FOLDER_ROOT dead last
        if (ainternal == Internal.USER_FOLDER_ROOT)
            return 1;
        else if (binternal == Internal.USER_FOLDER_ROOT)
            return -1;
        
        // sort everything else by name
        string aname;
        model.get(aiter, Column.NAME, out aname);
        
        string bname;
        model.get(biter, Column.NAME, out bname);
        
        return strcmp(aname.down(), bname.down());
    }
}

