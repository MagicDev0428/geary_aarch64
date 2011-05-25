/* Copyright 2011 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

public class Geary.RFC822.MailboxAddress {
    public string? name { get; private set; }
    public string? source_route { get; private set; }
    public string mailbox { get; private set; }
    public string domain { get; private set; }
    public string address { get; private set; }
    
    public MailboxAddress(string? name, string? source_route, string mailbox, string domain) {
        this.name = name;
        this.source_route = source_route;
        this.mailbox = mailbox;
        this.domain = domain;
        
        address = "%s@%s".printf(mailbox, domain);
    }
    
    /**
     * Returns a human-readable formatted address, showing the name (if available) and the email 
     * address in angled brackets.
     */
    public string get_full_address() {
        return String.is_empty(name) ? "<%s>".printf(address) : "%s <%s>".printf(name, address);
    }
    
    public string to_string() {
        return get_full_address();
    }
}

