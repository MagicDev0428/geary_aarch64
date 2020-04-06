/*
 * Copyright © 2020 Michael Gratton <mike@vee.net>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

/**
 * A factory for constructing plugin folder stores and folder objects.
 *
 * This class provides a common implementation that shares folder
 * objects between different plugin context instances.
 */
internal class Application.FolderStoreFactory : Geary.BaseObject {


    private class FolderStoreImpl : Geary.BaseObject, Plugin.FolderStore {


        public override GLib.VariantType folder_variant_type {
            get { return this._folder_variant_type; }
        }
        private GLib.VariantType _folder_variant_type = new GLib.VariantType(
            "(sv)"
        );

        private Controller controller;
        private Gee.Map<Geary.Folder,FolderImpl> folders;


        public FolderStoreImpl(Controller controller,
                               Gee.Map<Geary.Folder,FolderImpl> folders) {
            this.controller = controller;
            this.folders = folders;
        }

        public Gee.Collection<Plugin.Folder> get_folders() {
            return this.folders.values.read_only_view;
        }

        public async Gee.Collection<Plugin.Folder> list_containing_folders(
            Plugin.EmailIdentifier target,
            GLib.Cancellable? cancellable
        ) throws GLib.Error {
            var id = target as EmailStoreFactory.IdImpl;
            var folders = new Gee.LinkedList<Plugin.Folder>();
            AccountContext context =
                this.controller.get_context_for_account(id.account);
            if (id != null && context != null) {
                Gee.MultiMap<Geary.EmailIdentifier,Geary.FolderPath>? multi_folders =
                    yield context.account.get_containing_folders_async(
                        Geary.Collection.single(id.backing),
                        cancellable
                    );
                if (multi_folders != null) {
                    foreach (var path in multi_folders.get(id.backing)) {
                        var folder = context.account.get_folder(path);
                        folders.add(this.folders.get(folder));
                    }
                }
            }
            return folders;
        }

        public Plugin.Folder? get_folder_from_variant(GLib.Variant variant) {
            Plugin.Folder? found = null;
            // XXX this is pretty inefficient
            foreach (var folder in this.folders.values) {
                if (folder.to_variant().equal(variant)) {
                    found = folder;
                    break;
                }
            }
            return found;
        }

        internal void destroy() {
            this.folders = Gee.Map.empty();
        }

    }


    private class AccountImpl : Geary.BaseObject, Plugin.Account {


        public string display_name {
            get { return this.backing.account.information.display_name; }
        }


        /** The underlying backing account context for this account. */
        internal AccountContext backing { get; private set; }


        public AccountImpl(AccountContext backing) {
            this.backing = backing;
        }

    }


    private class FolderImpl : Geary.BaseObject, Plugin.Folder {


        // These constants are used to determine the persistent id of
        // the folder. Changing these may break plugins.
        private const string ID_FORMAT = "%s:%s";
        private const string ID_PATH_SEP = ">";


        public string persistent_id {
            get { return this._persistent_id; }
        }
        private string _persistent_id;

        public string display_name {
            get { return this.backing.display_name; }
        }

        public Geary.Folder.SpecialUse used_as {
            get { return this.backing.folder.used_as; }
        }

        public Plugin.Account? account {
            get { return this._account; }
        }
        private AccountImpl? _account;

        // The underlying folder being represented
        internal FolderContext backing { get; private set; }


        public FolderImpl(FolderContext backing, AccountImpl? account) {
            this.backing = backing;
            this._account = account;
            this._persistent_id = ID_FORMAT.printf(
                account.backing.account.information.id,
                string.join(ID_PATH_SEP, backing.folder.path.as_array())
            );
            folder_type_changed();
        }

        public GLib.Variant to_variant() {
            Geary.Folder folder = this.backing.folder;
            return new GLib.Variant.tuple({
                    folder.account.information.id,
                        new GLib.Variant.variant(folder.path.to_variant())
            });
        }

        internal void folder_type_changed() {
            notify_property("used-as");
            notify_property("display-name");
        }

    }


    private Controller controller;

    private Gee.Map<Geary.AccountInformation,AccountImpl> accounts =
        new Gee.HashMap<Geary.AccountInformation,AccountImpl>();
    private Gee.Map<Geary.Folder,FolderImpl> folders =
        new Gee.HashMap<Geary.Folder,FolderImpl>();
    private Gee.Set<FolderStoreImpl> stores =
        new Gee.HashSet<FolderStoreImpl>();


    /**
     * Constructs a new factory instance.
     */
    public FolderStoreFactory(Controller controller) throws GLib.Error {
        this.controller = controller;
        this.controller.account_available.connect(
            on_account_available
        );
        this.controller.account_unavailable.connect(
            on_account_unavailable
        );
        foreach (var context in controller.get_account_contexts()) {
            add_account(context);
        }
        this.controller.application.window_added.connect(on_window_added);
        foreach (var main in this.controller.application.get_main_windows()) {
            main.notify["selected-folder"].connect(on_folder_selected);
        }
    }

    /** Clearing all state of the store. */
    public void destroy() throws GLib.Error {
        this.controller.application.window_added.disconnect(on_window_added);
        foreach (FolderStoreImpl store in this.stores) {
            store.destroy();
        }
        this.stores.clear();

        this.controller.account_available.disconnect(
            on_account_available
        );
        this.controller.account_unavailable.disconnect(
            on_account_unavailable
        );
        // take a copy of the key set so the iterator doesn't asplode
        // as accounts are removed
        foreach (var context in this.accounts.values.to_array()) {
            remove_account(context.backing);
        }
        this.folders.clear();
    }

    /** Constructs a new folder store for use by plugin contexts. */
    public Plugin.FolderStore new_folder_store() {
        var store = new FolderStoreImpl(this.controller, this.folders);
        this.stores.add(store);
        return store;
    }

    /** Destroys a folder store once is no longer required. */
    public void destroy_folder_store(Plugin.FolderStore plugin) {
        FolderStoreImpl? impl = plugin as FolderStoreImpl;
        if (impl != null) {
            impl.destroy();
            this.stores.remove(impl);
        }
    }

    /** Returns the folder context for the given plugin folder. */
    public AccountContext get_account_context(Plugin.Account plugin) {
        AccountImpl? impl = plugin as AccountImpl;
        return (impl != null) ? impl.backing : null;
    }

    /** Returns the plugin folder for the given engine folder. */
    public Plugin.Folder? get_plugin_folder(Geary.Folder engine) {
        return this.folders.get(engine);
    }

    /** Returns the engine folder for the given plugin folder. */
    public Geary.Folder? get_engine_folder(Plugin.Folder plugin) {
        FolderImpl? impl = plugin as FolderImpl;
        return (impl != null) ? impl.backing.folder : null;
    }

    /** Returns the folder context for the given plugin folder. */
    public FolderContext get_folder_context(Plugin.Folder plugin) {
        FolderImpl? impl = plugin as FolderImpl;
        return (impl != null) ? impl.backing : null;
    }

    private void add_account(AccountContext added) {
        if (!this.accounts.has_key(added.account.information)) {
            this.accounts.set(added.account.information, new AccountImpl(added));
            added.folders_available.connect(on_folders_available);
            added.folders_unavailable.connect(on_folders_unavailable);
            added.account.folders_use_changed.connect(on_folders_use_changed);
            add_folders(added.get_folders());
         }
     }

    private void remove_account(AccountContext removed) {
        if (this.accounts.unset(removed.account.information)) {
            removed.folders_available.disconnect(on_folders_available);
            removed.folders_unavailable.disconnect(on_folders_unavailable);
            removed.account.folders_use_changed.disconnect(on_folders_use_changed);
            remove_folders(removed.get_folders());
        }
    }

    private void add_folders(Gee.Collection<FolderContext> to_add) {
        foreach (var context in to_add) {
            this.folders.set(
                context.folder,
                new FolderImpl(
                    context,
                    this.accounts.get(context.folder.account.information)
                )
            );
        }
        var folder_impls = to_plugin_folders(
            Geary.traverse(to_add)
            .map<Geary.Folder>((context => context.folder))
            .to_linked_list()
        ).read_only_view;
        foreach (FolderStoreImpl store in this.stores) {
            store.folders_available(folder_impls);
        }
    }

    private void remove_folders(Gee.Collection<FolderContext> to_remove) {
        foreach (var context in to_remove) {
            this.folders.unset(context.folder);
        }
        var folder_impls = to_plugin_folders(
            Geary.traverse(to_remove)
            .map<Geary.Folder>((context => context.folder))
            .to_linked_list()
        ).read_only_view;
        foreach (FolderStoreImpl store in this.stores) {
            store.folders_unavailable(folder_impls);
        }
    }

    private Gee.Collection<FolderImpl> to_plugin_folders(
        Gee.Collection<Geary.Folder> folders
    ) {
        return Geary.traverse(
            folders
        ).map<FolderImpl>(
            (f) => this.folders.get(f)
        ).to_linked_list().read_only_view;
    }

    private void on_account_available(AccountContext available) {
        add_account(available);
    }

    private void on_account_unavailable(AccountContext unavailable) {
        remove_account(unavailable);
    }

    private void on_folders_available(AccountContext account,
                                      Gee.Collection<FolderContext> available) {
        add_folders(available);
    }

    private void on_folders_unavailable(AccountContext account,
                                        Gee.Collection<FolderContext> unavailable) {
        remove_folders(unavailable);
    }

    private void on_folders_use_changed(Geary.Account account,
                                        Gee.Collection<Geary.Folder> changed) {
        var folders = to_plugin_folders(changed);
        foreach (FolderImpl folder in folders) {
            folder.folder_type_changed();
        }
        foreach (FolderStoreImpl store in this.stores) {
            store.folders_type_changed(folders);
        }
    }


    private void on_window_added(Gtk.Window window) {
        var main = window as MainWindow;
        if (main != null) {
            main.notify["selected-folder"].connect(on_folder_selected);
        }
    }

    private void on_folder_selected(GLib.Object object, GLib.ParamSpec param) {
        var main = object as MainWindow;
        if (main != null) {
            Geary.Folder? selected = main.selected_folder;
            if (selected != null) {
                var plugin = get_plugin_folder(selected);
                if (plugin != null) {
                    foreach (FolderStoreImpl store in this.stores) {
                        store.folder_selected(plugin);
                    }
                }
            }
        }
    }

}
