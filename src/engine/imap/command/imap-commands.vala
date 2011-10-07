/* Copyright 2011 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

public class Geary.Imap.CapabilityCommand : Command {
    public const string NAME = "capability";
    
    public CapabilityCommand() {
        base (NAME);
    }
}

public class Geary.Imap.NoopCommand : Command {
    public const string NAME = "noop";
    
    public NoopCommand() {
        base (NAME);
    }
}

public class Geary.Imap.LoginCommand : Command {
    public const string NAME = "login";
    
    public LoginCommand(string user, string pass) {
        base (NAME, { user, pass });
    }
    
    public override string to_string() {
        return "%s %s <user> <pass>".printf(tag.to_string(), name);
    }
}

public class Geary.Imap.LogoutCommand : Command {
    public const string NAME = "logout";
    
    public LogoutCommand() {
        base (NAME);
    }
}

public class Geary.Imap.ListCommand : Command {
    public const string NAME = "list";
    
    public ListCommand(string mailbox) {
        base (NAME, { "", mailbox });
    }
    
    public ListCommand.wildcarded(string reference, string mailbox) {
        base (NAME, { reference, mailbox });
    }
}

public class Geary.Imap.XListCommand : Command {
    public const string NAME = "xlist";
    
    public XListCommand(string mailbox) {
        base (NAME, { "", mailbox });
    }
    
    public XListCommand.wildcarded(string reference, string mailbox) {
        base (NAME, { reference, mailbox });
    }
}

public class Geary.Imap.ExamineCommand : Command {
    public const string NAME = "examine";
    
    public ExamineCommand(string mailbox) {
        base (NAME, { mailbox });
    }
}

public class Geary.Imap.SelectCommand : Command {
    public const string NAME = "select";
    
    public SelectCommand(string mailbox) {
        base (NAME, { mailbox });
    }
}

public class Geary.Imap.CloseCommand : Command {
    public const string NAME = "close";
    
    public CloseCommand() {
        base (NAME);
    }
}

public class Geary.Imap.FetchCommand : Command {
    public const string NAME = "fetch";
    public const string UID_NAME = "uid fetch";
    
    public FetchCommand(MessageSet msg_set, FetchDataType[] data_items) {
        base (msg_set.is_uid ? UID_NAME : NAME);
        
        add(msg_set.to_parameter());
        
        assert(data_items.length > 0);
        if (data_items.length == 1) {
            add(data_items[0].to_parameter());
        } else {
            ListParameter data_item_list = new ListParameter(this);
            foreach (FetchDataType data_item in data_items)
                data_item_list.add(data_item.to_parameter());
            
            add(data_item_list);
        }
    }
    
    public FetchCommand.from_collection(MessageSet msg_set, Gee.Collection<FetchDataType> data_items) {
        base (msg_set.is_uid ? UID_NAME : NAME);
        
        add(msg_set.to_parameter());
        
        assert(data_items.size > 0);
        if (data_items.size == 1) {
            foreach (FetchDataType data_type in data_items) {
                add(data_type.to_parameter());
                
                break;
            }
        } else {
            ListParameter data_item_list = new ListParameter(this);
            foreach (FetchDataType data_item in data_items)
                data_item_list.add(data_item.to_parameter());
            
            add(data_item_list);
        }
    }
}

public class Geary.Imap.StatusCommand : Command {
    public const string NAME = "status";
    
    public StatusCommand(string mailbox, StatusDataType[] data_items) {
        base (NAME);
        
        add (new StringParameter(mailbox));
        
        assert(data_items.length > 0);
        ListParameter data_item_list = new ListParameter(this);
        foreach (StatusDataType data_item in data_items)
            data_item_list.add(data_item.to_parameter());
        
        add(data_item_list);
    }
}

