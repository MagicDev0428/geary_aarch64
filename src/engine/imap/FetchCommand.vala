/* Copyright 2011 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

// TODO: Support body[section]<partial> and body.peek[section]<partial> forms
public enum Geary.Imap.FetchDataItem {
    UID,
    FLAGS,
    INTERNALDATE,
    ENVELOPE,
    BODYSTRUCTURE,
    BODY,
    RFC822,
    RFC822_HEADER,
    RFC822_SIZE,
    RFC822_TEXT,
    FAST,
    ALL,
    FULL;
    
    public string to_string() {
        switch (this) {
            case UID:
                return "uid";
            
            case FLAGS:
                return "flags";
            
            case INTERNALDATE:
                return "internaldate";
            
            case ENVELOPE:
                return "envelope";
            
            case BODYSTRUCTURE:
                return "bodystructure";
            
            case BODY:
                return "body";
            
            case RFC822:
                return "rfc822";
            
            case RFC822_HEADER:
                return "rfc822.header";
            
            case RFC822_SIZE:
                return "rfc822.size";
            
            case RFC822_TEXT:
                return "rfc822.text";
            
            case FAST:
                return "fast";
            
            case ALL:
                return "all";
            
            case FULL:
                return "full";
            
            default:
                assert_not_reached();
        }
    }
    
    public static FetchDataItem decode(string value) throws ImapError {
        switch (value.down()) {
            case "uid":
                return UID;
            
            case "flags":
                return FLAGS;
            
            case "internaldate":
                return INTERNALDATE;
            
            case "envelope":
                return ENVELOPE;
            
            case "bodystructure":
                return BODYSTRUCTURE;
            
            case "body":
                return BODY;
            
            case "rfc822":
                return RFC822;
            
            case "rfc822.header":
                return RFC822_HEADER;
            
            case "rfc822.size":
                return RFC822_SIZE;
            
            case "rfc822.text":
                return RFC822_TEXT;
            
            case "fast":
                return FAST;
            
            case "all":
                return ALL;
            
            case "full":
                return FULL;
            
            default:
                throw new ImapError.PARSE_ERROR("\"%s\" is not a valid fetch-command data item", value);
        }
    }
    
    public StringParameter to_parameter() {
        return new StringParameter(to_string());
    }
    
    public static FetchDataItem from_parameter(StringParameter strparam) throws ImapError {
        return decode(strparam.value);
    }
    
    public FetchDataDecoder? get_decoder() {
        switch (this) {
            case UID:
                return new UIDDecoder();
            
            case FLAGS:
                return new FlagsDecoder();
            
            case ENVELOPE:
                return new EnvelopeDecoder();
            
            case INTERNALDATE:
                return new InternalDateDecoder();
            
            case RFC822_SIZE:
                return new RFC822SizeDecoder();
            
            case RFC822_HEADER:
                return new RFC822HeaderDecoder();
            
            case RFC822_TEXT:
                return new RFC822TextDecoder();
            
            case RFC822:
                return new RFC822FullDecoder();
            
            default:
                return null;
        }
    }
}

public class Geary.Imap.FetchCommand : Command {
    public const string NAME = "fetch";
    
    public FetchCommand(Tag tag, string msg_span, FetchDataItem[] data_items) {
        base (tag, NAME);
        
        add(new StringParameter(msg_span));
        
        assert(data_items.length > 0);
        if (data_items.length == 1) {
            add(data_items[0].to_parameter());
        } else {
            ListParameter data_item_list = new ListParameter(this);
            foreach (FetchDataItem data_item in data_items)
                data_item_list.add(data_item.to_parameter());
            
            add(data_item_list);
        }
    }
}

