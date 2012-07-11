/* Copyright 2011-2012 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

public class Geary.AccountInformation : Object {
    private const string GROUP = "AccountInformation";
    private const string REAL_NAME_KEY = "real_name";
    private const string SERVICE_PROVIDER_KEY = "service_provider";
    private const string REMEMBER_PASSWORD_KEY = "remember_password";
    private const string IMAP_HOST = "imap_host";
    private const string IMAP_PORT = "imap_port";
    private const string IMAP_SSL = "imap_ssl";
    private const string IMAP_PIPELINE = "imap_pipeline";
    private const string SMTP_HOST = "smtp_host";
    private const string SMTP_PORT = "smtp_port";
    private const string SMTP_SSL = "smtp_ssl";
    
    public const string SETTINGS_FILENAME = "geary.ini";
    
    internal File? settings_dir;
    internal File? file = null;
    public string real_name { get; set; }
    public Geary.ServiceProvider service_provider { get; set; }
    public bool imap_server_pipeline { get; set; default = true; }

    // These properties are only used if the service provider's account type does not override them.
    public string default_imap_server_host { get; set; }
    public uint16 default_imap_server_port  { get; set; }
    public bool default_imap_server_ssl  { get; set; }
    public string default_smtp_server_host  { get; set; }
    public uint16 default_smtp_server_port  { get; set; }
    public bool default_smtp_server_ssl  { get; set; }

    public Geary.Credentials credentials { get; private set; }
    public bool remember_password { get; set; default = true; }
    
    public AccountInformation(Geary.Credentials credentials) {
        this.credentials = credentials;
        
        this.settings_dir = Geary.Engine.user_data_dir.get_child(credentials.user);
        this.file = settings_dir.get_child(SETTINGS_FILENAME);
    }
    
    public void load_info_from_file() {
        KeyFile key_file = new KeyFile();
        try {
            key_file.load_from_file(file.get_path() ?? "", KeyFileFlags.NONE);
        } catch (FileError err) {
            // See comment in next catch block.
        } catch (KeyFileError err) {
            // It's no big deal if we couldn't load the key file -- just means we give you the defaults.
        } finally {
            real_name = get_string_value(key_file, GROUP, REAL_NAME_KEY);
            remember_password = get_bool_value(key_file, GROUP, REMEMBER_PASSWORD_KEY, true);
            service_provider = Geary.ServiceProvider.from_string(get_string_value(key_file, GROUP,
                SERVICE_PROVIDER_KEY));
            
            imap_server_pipeline = get_bool_value(key_file, GROUP, IMAP_PIPELINE, true);

            if (service_provider == ServiceProvider.OTHER) {
                default_imap_server_host = get_string_value(key_file, GROUP, IMAP_HOST);
                default_imap_server_port = get_uint16_value(key_file, GROUP, IMAP_PORT,
                    Imap.ClientConnection.DEFAULT_PORT_SSL);
                default_imap_server_ssl = get_bool_value(key_file, GROUP, IMAP_SSL, true);
                
                default_smtp_server_host = get_string_value(key_file, GROUP, SMTP_HOST);
                default_smtp_server_port = get_uint16_value(key_file, GROUP, SMTP_PORT,
                    Geary.Smtp.ClientConnection.DEFAULT_PORT_SSL);
                default_smtp_server_ssl = get_bool_value(key_file, GROUP, SMTP_SSL, true);
            }
        }
    }
    
    public async bool validate_async(Cancellable? cancellable = null) throws EngineError {
        AccountSettings settings = new AccountSettings(this);
        
        Geary.Imap.ClientSessionManager client_session_manager = new Geary.Imap.ClientSessionManager(
            settings, 0);
        Geary.Imap.ClientSession? client_session = null;
        try {
            client_session = yield client_session_manager.get_authorized_session_async(cancellable);
        } catch (Error err) {
            debug("Error validating account info: %s", err.message);
        }
        
        if (client_session != null) {
            string current_mailbox;
            return client_session.get_context(out current_mailbox) == Geary.Imap.ClientSession.Context.AUTHORIZED;
        }
        
        return false;
    }

    public Endpoint get_imap_endpoint() throws EngineError {
        switch (service_provider) {
            case ServiceProvider.GMAIL:
                return GmailAccount.IMAP_ENDPOINT;
            
            case ServiceProvider.YAHOO:
                return YahooAccount.IMAP_ENDPOINT;
            
            case ServiceProvider.OTHER:
                Endpoint.Flags imap_flags = default_imap_server_ssl ? Endpoint.Flags.SSL :
                    Endpoint.Flags.NONE;
                imap_flags |= Endpoint.Flags.GRACEFUL_DISCONNECT;
                
                return new Endpoint(default_imap_server_host, default_imap_server_port,
                    imap_flags, Imap.ClientConnection.RECOMMENDED_TIMEOUT_SEC);
            
            default:
                throw new EngineError.NOT_FOUND("Service provider of type %s not known",
                    service_provider.to_string());
        }
    }

    public Endpoint get_smtp_endpoint() throws EngineError {
        switch (service_provider) {
            case ServiceProvider.GMAIL:
                return GmailAccount.SMTP_ENDPOINT;
            
            case ServiceProvider.YAHOO:
                return YahooAccount.SMTP_ENDPOINT;
            
            case ServiceProvider.OTHER:
                Endpoint.Flags smtp_flags = default_smtp_server_ssl ? Endpoint.Flags.SSL :
                    Endpoint.Flags.NONE;
                smtp_flags |= Geary.Endpoint.Flags.GRACEFUL_DISCONNECT;
                
                return new Endpoint(default_smtp_server_host, default_smtp_server_port,
                    smtp_flags, Smtp.ClientConnection.DEFAULT_TIMEOUT_SEC);
            
            default:
                throw new EngineError.NOT_FOUND("Service provider of type %s not known",
                    service_provider.to_string());
        }
    }

    public Geary.EngineAccount get_account() throws EngineError {
        AccountSettings settings = new AccountSettings(this);
        
        ImapDB.Account local_account = new ImapDB.Account(settings);
        Imap.Account remote_account = new Imap.Account(settings);

        switch (service_provider) {
            case ServiceProvider.GMAIL:
                return new GmailAccount("Gmail account %s".printf(credentials.to_string()), settings,
                    remote_account, local_account);
            
            case ServiceProvider.YAHOO:
                return new YahooAccount("Yahoo account %s".printf(credentials.to_string()), settings,
                    remote_account, local_account);
            
            case ServiceProvider.OTHER:
                return new OtherAccount("Other account %s".printf(credentials.to_string()), settings,
                    remote_account, local_account);
                
            default:
                throw new EngineError.NOT_FOUND("Service provider of type %s not known",
                    service_provider.to_string());
        }
    }
    
    private string get_string_value(KeyFile key_file, string group, string key, string _default = "") {
        string v = _default;
        try {
            v = key_file.get_value(group, key);
        } catch(KeyFileError err) {
            // Ignore.
        }
        return v;
    }
    
    private bool get_bool_value(KeyFile key_file, string group, string key, bool _default = false) {
        bool v = _default;
        try {
            v = key_file.get_boolean(group, key);
        } catch(KeyFileError err) {
            // Ignore.
        }
        return v;
    }
    
    private uint16 get_uint16_value(KeyFile key_file, string group, string key, uint16 _default = 0) {
        uint16 v = _default;
        try {
            v = (uint16) key_file.get_integer(group, key);
        } catch(KeyFileError err) {
            // Ignore.
        }
        return v;
    }
    
    public async void store_async(Cancellable? cancellable = null) {
        assert(file != null);
        
        if (!settings_dir.query_exists(cancellable)) {
            try {
                settings_dir.make_directory_with_parents();
            } catch (Error err) {
                error("Error creating settings directory for user '%s': %s", credentials.user,
                    err.message);
            }
        }
        
        if (!file.query_exists(cancellable)) {
            try {
                yield file.create_async(FileCreateFlags.REPLACE_DESTINATION);
            } catch (Error err) {
                debug("Error creating account info file: %s", err.message);
            }
        }
        
        KeyFile key_file = new KeyFile();
        
        key_file.set_value(GROUP, REAL_NAME_KEY, real_name);
        key_file.set_value(GROUP, SERVICE_PROVIDER_KEY, service_provider.to_string());
        key_file.set_boolean(GROUP, REMEMBER_PASSWORD_KEY, remember_password);
        
        key_file.set_boolean(GROUP, IMAP_PIPELINE, imap_server_pipeline);

        if (service_provider == ServiceProvider.OTHER) {
            key_file.set_value(GROUP, IMAP_HOST, default_imap_server_host);
            key_file.set_integer(GROUP, IMAP_PORT, default_imap_server_port);
            key_file.set_boolean(GROUP, IMAP_SSL, default_imap_server_ssl);
            
            key_file.set_value(GROUP, SMTP_HOST, default_smtp_server_host);
            key_file.set_integer(GROUP, SMTP_PORT, default_smtp_server_port);
            key_file.set_boolean(GROUP, SMTP_SSL, default_smtp_server_ssl);
        }
        
        string data = key_file.to_data();
        string new_etag;
        
        try {
            yield file.replace_contents_async(data.data, null, false, FileCreateFlags.NONE,
                cancellable, out new_etag);
        } catch (Error err) {
            debug("Error writing to account info file: %s", err.message);
        }
    }
}
