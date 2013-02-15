/* Copyright 2011-2012 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

public class FolderList.Tree : Sidebar.Tree {

    public const Gtk.TargetEntry[] TARGET_ENTRY_LIST = {
        { "application/x-geary-mail", Gtk.TargetFlags.SAME_APP, 0 }
    };
    
    public signal void folder_selected(Geary.Folder? folder);
    public signal void copy_conversation(Geary.Folder folder);
    public signal void move_conversation(Geary.Folder folder);
    
    private Gee.HashMap<Geary.Account, AccountBranch> account_branches
        = new Gee.HashMap<Geary.Account, AccountBranch>();
    private InboxesBranch inboxes_branch = new InboxesBranch();
    private int total_accounts = 0;
    private NewMessagesMonitor? monitor = null;
    
    public Tree() {
        base(new Gtk.TargetEntry[0], Gdk.DragAction.ASK, drop_handler);
        entry_selected.connect(on_entry_selected);

        // Set self as a drag destination.
        Gtk.drag_dest_set(this, Gtk.DestDefaults.MOTION | Gtk.DestDefaults.HIGHLIGHT,
            TARGET_ENTRY_LIST, Gdk.DragAction.COPY | Gdk.DragAction.MOVE);
    }
    
    ~FolderList() {
        set_new_messages_monitor(null);
    }
    
    private void drop_handler(Gdk.DragContext context, Sidebar.Entry? entry,
        Gtk.SelectionData data, uint info, uint time) {
    }
    
    private FolderEntry? get_folder_entry(Geary.Folder folder) {
        AccountBranch? account_branch = account_branches.get(folder.account);
        return (account_branch == null ? null :
            account_branch.get_entry_for_path(folder.get_path()));
    }
    
    private void on_entry_selected(Sidebar.SelectableEntry selectable) {
        if (selectable is FolderEntry) {
            folder_selected(((FolderEntry) selectable).folder);
        }
    }

    private void on_new_messages_changed(Geary.Folder folder, int count) {
        FolderEntry? entry = get_folder_entry(folder);
        if (entry != null)
            entry.set_has_unread(count > 0);
    }
    
    public void set_new_messages_monitor(NewMessagesMonitor? monitor) {
        if (this.monitor != null) {
            this.monitor.new_messages_arrived.disconnect(on_new_messages_changed);
            this.monitor.new_messages_retired.disconnect(on_new_messages_changed);
        }
        
        this.monitor = monitor;
        if (this.monitor != null) {
            this.monitor.new_messages_arrived.connect(on_new_messages_changed);
            this.monitor.new_messages_retired.connect(on_new_messages_changed);
        }
    }
    
    public void set_user_folders_root_name(Geary.Account account, string name) {
        if (account_branches.has_key(account))
            account_branches.get(account).user_folder_group.rename(name);
    }
    
    public void add_folder(Geary.Folder folder) {
        if (!account_branches.has_key(folder.account))
            account_branches.set(folder.account, new AccountBranch(folder.account));
        
        AccountBranch account_branch = account_branches.get(folder.account);
        if (!has_branch(account_branch)) {
            // 1 + ... because the Inboxes branch comes at position 0.
            graft(account_branch, 1 + total_accounts++);
        }
        
        if (account_branches.size > 1 && !has_branch(inboxes_branch))
            graft(inboxes_branch, 0); // The Inboxes branch comes first.
        if (folder.get_special_folder_type() == Geary.SpecialFolderType.INBOX)
            inboxes_branch.add_inbox(folder);
        
        account_branch.add_folder(folder);
    }

    public void remove_folder(Geary.Folder folder) {
        AccountBranch? account_branch = account_branches.get(folder.account);
        assert(account_branch != null);
        assert(has_branch(account_branch));
        
        // If this is the current folder, unselect it.
        Sidebar.Entry? entry = account_branch.get_entry_for_path(folder.get_path());
        if (entry == null || !is_selected(entry))
            entry = inboxes_branch.get_entry_for_account(folder.account);
        if (entry != null && is_selected(entry))
            folder_selected(null);
        
        if (folder.get_special_folder_type() == Geary.SpecialFolderType.INBOX)
            inboxes_branch.remove_inbox(folder.account);
        
        account_branch.remove_folder(folder);
    }
    
    public void remove_account(Geary.Account account) {
        AccountBranch? account_branch = account_branches.get(account);
        if (account_branch != null) {
            // If a folder on this account is selected, unselect it.
            foreach (FolderEntry entry in account_branch.folder_entries.values) {
                if (is_selected(entry)) {
                    folder_selected(null);
                    break;
                }
            }
            
            if (has_branch(account_branch))
                prune(account_branch);
            account_branches.unset(account);
        }
        
        Sidebar.Entry? entry = inboxes_branch.get_entry_for_account(account);
        if (entry != null && is_selected(entry))
            folder_selected(null);
        
        inboxes_branch.remove_inbox(account);
        
        if (account_branches.size <= 1 && has_branch(inboxes_branch))
            prune(inboxes_branch);
    }
    
    public void select_folder(Geary.Folder folder) {
        FolderEntry? entry = get_folder_entry(folder);
        if (entry != null)
            place_cursor(entry, false);
    }
    
    public bool select_inbox(Geary.Account account) {
        if (!has_branch(inboxes_branch))
            return false;
        
        InboxFolderEntry? entry = inboxes_branch.get_entry_for_account(account);
        if (entry == null)
            return false;
        
        place_cursor(entry, false);
        return true;
    }
    
    public override bool drag_motion(Gdk.DragContext context, int x, int y, uint time) {
        // Run the base version first.
        bool ret = base.drag_motion(context, x, y, time);

        // Update the cursor for copy or move.
        Gdk.ModifierType mask;
        double[] axes = new double[2];
        context.get_device().get_state(context.get_dest_window(), axes, out mask);
        if ((mask & Gdk.ModifierType.CONTROL_MASK) != 0) {
            Gdk.drag_status(context, Gdk.DragAction.COPY, time);
        } else {
            Gdk.drag_status(context, Gdk.DragAction.MOVE, time);
        }
        return ret;
    }
}
