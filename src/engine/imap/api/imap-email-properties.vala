/* Copyright 2011 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

public class Geary.Imap.EmailProperties : Geary.EmailProperties {
    public bool answered { get; private set; }
    public bool deleted { get; private set; }
    public bool draft { get; private set; }
    public bool flagged { get; private set; }
    public bool recent { get; private set; }
    public bool seen { get; private set; }
    public MessageFlags flags { get; private set; }
    public InternalDate? internaldate { get; private set; }
    public RFC822.Size? rfc822_size { get; private set; }
    
    public EmailProperties(MessageFlags flags, InternalDate? internaldate, RFC822.Size? rfc822_size) {
        this.flags = flags;
        this.internaldate = internaldate;
        this.rfc822_size = rfc822_size;
        
        answered = flags.contains(MessageFlag.ANSWERED);
        deleted = flags.contains(MessageFlag.DELETED);
        draft = flags.contains(MessageFlag.DRAFT);
        flagged = flags.contains(MessageFlag.FLAGGED);
        recent = flags.contains(MessageFlag.RECENT);
        seen = flags.contains(MessageFlag.SEEN);
    }
    
    public override bool is_unread() {
        return !flags.contains(MessageFlag.SEEN);
    }
}

