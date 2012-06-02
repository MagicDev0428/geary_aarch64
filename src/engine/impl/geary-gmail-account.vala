/* Copyright 2011-2012 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

private class Geary.GmailAccount : Geary.GenericImapAccount {
    private const string GMAIL_FOLDER = "[Gmail]";
    
    private static Geary.Endpoint? _imap_endpoint = null;
    public static Geary.Endpoint IMAP_ENDPOINT { get {
        if (_imap_endpoint == null) {
            _imap_endpoint = new Geary.Endpoint(
                "imap.gmail.com",
                Imap.ClientConnection.DEFAULT_PORT_SSL,
                Geary.Endpoint.Flags.SSL | Geary.Endpoint.Flags.GRACEFUL_DISCONNECT,
                Imap.ClientConnection.RECOMMENDED_TIMEOUT_SEC);
        }
        
        return _imap_endpoint;
    } }
    
    private static Geary.Endpoint? _smtp_endpoint = null;
    public static Geary.Endpoint SMTP_ENDPOINT { get {
        if (_smtp_endpoint == null) {
            _smtp_endpoint = new Geary.Endpoint(
                "smtp.gmail.com",
                Smtp.ClientConnection.DEFAULT_PORT_SSL,
                Geary.Endpoint.Flags.SSL | Geary.Endpoint.Flags.GRACEFUL_DISCONNECT,
                Smtp.ClientConnection.DEFAULT_TIMEOUT_SEC);
        }
        
        return _smtp_endpoint;
    } }
    
    private static SpecialFolderMap? special_folder_map = null;
    private static Gee.Set<Geary.FolderPath>? ignored_paths = null;
    
    public GmailAccount(string name, string username, AccountInformation account_info,
        File user_data_dir, Imap.Account remote, Sqlite.Account local) {
        base (name, username, account_info, user_data_dir, remote, local);
        
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
        ignored_paths.add(new Geary.FolderRoot(Imap.Account.INBOX_NAME, Imap.Account.ASSUMED_SEPARATOR,
            true));
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
    
    public override bool delete_is_archive() {
        return true;
    }
}

