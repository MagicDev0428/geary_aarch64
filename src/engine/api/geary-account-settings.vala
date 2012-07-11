/* Copyright 2012 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

/**
 * AccountSettings is a complement to AccountInformation.  AccountInformation stores these settings
 * as well as defaults and provides validation and persistence functionality.  Settings is simply
 * the values loaded from a backing store, perhaps chosen from defaults, and validated filtered
 * down to a set of working settings for the Account to use.
 */

public class Geary.AccountSettings {
    public string real_name { get; private set; }
    public Geary.Credentials credentials { get; private set; }
    public Geary.ServiceProvider service_provider { get; private set; }
    public bool imap_server_pipeline { get; private set; }
    public Endpoint imap_endpoint { get; private set; }
    public Endpoint smtp_endpoint { get; private set; }
    
    internal AccountSettings(AccountInformation info) throws EngineError {
        real_name = info.real_name;
        credentials = info.credentials;
        service_provider = info.service_provider;
        imap_server_pipeline = info.imap_server_pipeline;
        imap_endpoint = info.get_imap_endpoint();
        smtp_endpoint = info.get_smtp_endpoint();
    }
}

