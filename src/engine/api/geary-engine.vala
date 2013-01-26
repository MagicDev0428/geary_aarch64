/* Copyright 2011-2012 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

public class Geary.Engine {
    private static Engine? _instance = null;
    public static Engine instance {
        get {
            if (_instance == null)
                _instance = new Engine();

            return _instance;
        }
    }

    public File? user_data_dir { get; private set; default = null; }
    public File? resource_dir { get; private set; default = null; }
    public Geary.CredentialsMediator? authentication_mediator { get; private set; default = null; }

    private bool is_open = false;
    private Gee.HashMap<string, AccountInformation>? accounts = null;
    private Gee.HashMap<string, Account>? account_instances = null;

    /**
     * Fired when the engine is opened.
     */
    public signal void opened();

    /**
     * Fired when the engine is closed.
     */
    public signal void closed();

    /**
     * Fired when an account becomes available in the engine.  Opening the
     * engine makes all existing accounts available; newly created accounts are
     * also made available as soon as they're stored.
     */
    public signal void account_available(AccountInformation account);

    /**
     * Fired when an account becomes unavailable in the engine.  Closing the
     * engine makes all accounts unavailable; deleting an account also makes it
     * unavailable.
     */
    public signal void account_unavailable(AccountInformation account);

    /**
     * Fired when a new account is created.
     */
    public signal void account_added(AccountInformation account);

    /**
     * Fired when an account is deleted.
     */
    public signal void account_removed(AccountInformation account);

    private Engine() {
        // Initialize GMime
        GMime.init(0);
    }

    private void check_opened() throws EngineError {
        if (!is_open)
            throw new EngineError.OPEN_REQUIRED("Geary.Engine instance not open");
    }

    /**
     * Initializes the engine, and makes all existing accounts available.  The
     * given authentication mediator will be used to retrieve all passwords
     * when necessary.
     */
    public async void open_async(File user_data_dir, File resource_dir,
                                 Geary.CredentialsMediator? authentication_mediator,
                                 Cancellable? cancellable = null) throws Error {
        if (is_open)
            throw new EngineError.ALREADY_OPEN("Geary.Engine instance already open");

        this.user_data_dir = user_data_dir;
        this.resource_dir = resource_dir;
        this.authentication_mediator = authentication_mediator;

        accounts = new Gee.HashMap<string, AccountInformation>();
        account_instances = new Gee.HashMap<string, Account>();

        is_open = true;
        opened();

        yield add_existing_accounts_async(cancellable);
   }

    private async void add_existing_accounts_async(Cancellable? cancellable = null) throws Error {
        try {
            user_data_dir.make_directory_with_parents(cancellable);
        } catch (IOError e) {
            if (!(e is IOError.EXISTS))
                throw e;
        }

        FileEnumerator enumerator
            = yield user_data_dir.enumerate_children_async("standard::*",
                FileQueryInfoFlags.NONE, Priority.DEFAULT, cancellable);

        for (;;) {
            List<FileInfo> info_list;
            try {
                info_list = yield enumerator.next_files_async(1, Priority.DEFAULT, cancellable);
            } catch (Error e) {
                debug("Error enumerating existing accounts: %s", e.message);
                break;
            }

            if (info_list.length() == 0)
                break;

            FileInfo info = info_list.nth_data(0);
            if (info.get_file_type() == FileType.DIRECTORY) {
                // TODO: check for geary.ini
                add_account(new AccountInformation(user_data_dir.get_child(info.get_name())));
            }
        }
     }

    /**
     * Uninitializes the engine, and makes all accounts unavailable.
     */
    public async void close_async(Cancellable? cancellable = null) throws Error {
        if (!is_open)
            return;

        foreach(AccountInformation account in accounts.values)
            account_unavailable(account);

        user_data_dir = null;
        resource_dir = null;
        authentication_mediator = null;
        accounts = null;
        account_instances = null;

        is_open = false;
        closed();
    }

    /**
     * Returns the current accounts list as a map keyed by email address.
     */
    public Gee.Map<string, AccountInformation> get_accounts() throws Error {
        check_opened();

        return accounts.read_only_view;
    }

    /**
     * Returns a new account for the given email address not yet stored on disk.
     */
    public AccountInformation create_orphan_account(string email) throws Error {
        check_opened();

        if (accounts.has_key(email))
            throw new EngineError.ALREADY_EXISTS("Account %s already exists", email);

        return new AccountInformation(user_data_dir.get_child(email));
    }
    
    /**
     * Returns whether the account information "validates", which means here
     * that we can connect to the endpoints and authenticate using the supplied
     * credentials.
     */
    public async bool validate_account_information_async(AccountInformation account,
        Cancellable? cancellable = null) throws Error {
        check_opened();
        
        // validate IMAP, which requires logging in and establishing an AUTHORIZED cx state
        bool imap_valid = false;
        Geary.Imap.ClientSession? imap_session = new Imap.ClientSession(account.get_imap_endpoint(), true);
        try {
            yield imap_session.connect_async(cancellable);
            yield imap_session.initiate_session_async(account.imap_credentials, cancellable);
            
            // Connected and initiated, still need to be sure connection authorized
            string current_mailbox;
            if (imap_session.get_context(out current_mailbox) == Imap.ClientSession.Context.AUTHORIZED)
                imap_valid = true;
        } catch (Error err) {
            debug("Error validating IMAP account info: %s", err.message);
            
            // fall through so session can be disconnected
        }
        
        try {
            yield imap_session.disconnect_async(cancellable);
        } catch (Error err) {
            // ignored
        } finally {
            imap_session = null;
        }
        
        if (!imap_valid)
            return false;
        
        // SMTP is simpler, merely see if login works and done (throws an SmtpError if not)
        bool smtp_valid = false;
        Geary.Smtp.ClientSession? smtp_session = new Geary.Smtp.ClientSession(account.get_smtp_endpoint());
        try {
            yield smtp_session.login_async(account.smtp_credentials, cancellable);
            smtp_valid = true;
        } catch (Error err) {
            debug("Error validating SMTP account info: %s", err.message);
            
            // fall through so session can be disconnected
        }
        
        try {
            yield smtp_session.logout_async(cancellable);
        } catch (Error err) {
            // ignored
        } finally {
            smtp_session = null;
        }
        
        return smtp_valid;
    }
    
    /**
     * Creates a Geary.Account from a Geary.AccountInformation (which is what
     * other methods in this interface deal in).
     */
    public Geary.Account get_account_instance(AccountInformation account_information)
        throws Error {
        check_opened();
        
        if (account_instances.has_key(account_information.email))
            return account_instances.get(account_information.email);
        
        AccountSettings settings = new AccountSettings(account_information);
        ImapDB.Account local_account = new ImapDB.Account(settings);
        Imap.Account remote_account = new Imap.Account(settings);
        
        Geary.Account account;
        switch (account_information.service_provider) {
            case ServiceProvider.GMAIL:
                account = new ImapEngine.GmailAccount("Gmail account %s".printf(account_information.email),
                    settings, remote_account, local_account);
            break;
            
            case ServiceProvider.YAHOO:
                account = new ImapEngine.YahooAccount("Yahoo account %s".printf(account_information.email),
                    settings, remote_account, local_account);
            break;
            
            case ServiceProvider.OTHER:
                account = new ImapEngine.OtherAccount("Other account %s".printf(account_information.email),
                    settings, remote_account, local_account);
            break;
                
            default:
                assert_not_reached();
        }
        
        account_instances.set(account_information.email, account);
        return account;
    }
    
    /**
     * Adds the account to be tracked by the engine.  Should only be called from
     * AccountInformation.store_async() and this class.
     */
    internal void add_account(AccountInformation account, bool created = false) throws Error {
        check_opened();

        bool already_added = accounts.has_key(account.email);

        accounts.set(account.email, account);

        if (!already_added) {
            if (created)
                account_added(account);
            account_available(account);
        }
    }

    /**
     * Deletes the account from disk.
     */
    public async void remove_account_async(AccountInformation account,
                                           Cancellable? cancellable = null) throws Error {
        check_opened();

        if (accounts.unset(account.email)) {
            account_unavailable(account);

            // TODO: delete the account from disk.
            account_removed(account);
            
            account_instances.unset(account.email);
        }
    }
}

