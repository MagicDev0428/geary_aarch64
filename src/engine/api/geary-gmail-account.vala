/* Copyright 2011 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

private class Geary.GmailAccount : Geary.GenericImapAccount {
    private const string GMAIL_FOLDER = "[Gmail]";
    
    private static SpecialFolderMap? special_folder_map = null;
    private static Gee.Set<Geary.FolderPath>? ignored_paths = null;
    
    public GmailAccount(string name, RemoteAccount remote, LocalAccount local) {
        base (name, remote, local);
        
        if (special_folder_map == null || ignored_paths == null)
            initialize_personality();
    }
    
    private static void initialize_personality() {
        Geary.FolderPath gmail_root = new Geary.FolderRoot(GMAIL_FOLDER, Imap.Account.ASSUMED_SEPARATOR,
            true);
        
        special_folder_map = new SpecialFolderMap();
        special_folder_map.set_folder(new SpecialFolder(Geary.SpecialFolderType.INBOX, _("Inbox"),
            new Geary.FolderRoot(Imap.Account.INBOX_NAME, Imap.Account.ASSUMED_SEPARATOR, false), 0));
        special_folder_map.set_folder(new SpecialFolder(Geary.SpecialFolderType.DRAFTS, _("Drafts"),
            gmail_root.get_child("Drafts"), 1));
        special_folder_map.set_folder(new SpecialFolder(Geary.SpecialFolderType.SENT, _("Sent Mail"),
            gmail_root.get_child("Sent Mail"), 2));
        special_folder_map.set_folder(new SpecialFolder(Geary.SpecialFolderType.FLAGGED, _("Starred"),
            gmail_root.get_child("Starred"), 3));
        special_folder_map.set_folder(new SpecialFolder(Geary.SpecialFolderType.ALL_MAIL, _("All Mail"),
            gmail_root.get_child("All Mail"), 4));
        special_folder_map.set_folder(new SpecialFolder(Geary.SpecialFolderType.SPAM, _("Spam"),
            gmail_root.get_child("Spam"), 5));
        special_folder_map.set_folder(new SpecialFolder(Geary.SpecialFolderType.TRASH, _("Trash"),
            gmail_root.get_child("Trash"), 6));
        
        ignored_paths = new Gee.HashSet<Geary.FolderPath>(Hashable.hash_func, Equalable.equal_func);
        ignored_paths.add(gmail_root);
    }
    
    public override string get_user_folders_label() {
        return _("Labels");
    }
    
    public override Geary.SpecialFolderMap? get_special_folder_map() {
        return special_folder_map;
    }
    
    public override Gee.Set<Geary.FolderPath>? get_ignored_paths() {
        return ignored_paths.read_only_view;
    }
}

