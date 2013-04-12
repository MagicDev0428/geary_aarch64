/* Copyright 2011-2013 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution.
 */

public enum Geary.Imap.ServerDataType {
    CAPABILITY,
    EXISTS,
    EXPUNGE,
    FETCH,
    FLAGS,
    LIST,
    LSUB,
    RECENT,
    SEARCH,
    STATUS;
    
    public string to_string() {
        switch (this) {
            case CAPABILITY:
                return "capability";
            
            case EXISTS:
                return "exists";
            
            case EXPUNGE:
                return "expunge";
            
            case FETCH:
                return "fetch";
            
            case FLAGS:
                return "flags";
            
            case LIST:
                return "list";
            
            case LSUB:
                return "lsub";
            
            case RECENT:
                return "recent";
            
            case SEARCH:
                return "search";
            
            case STATUS:
                return "status";
            
            default:
                assert_not_reached();
        }
    }
    
    public static ServerDataType decode(string value) throws ImapError {
        switch (value.down()) {
            case "capability":
                return CAPABILITY;
            
            case "exists":
                return EXISTS;
            
            case "expunge":
                return EXPUNGE;
            
            case "fetch":
                return FETCH;
            
            case "flags":
                return FLAGS;
            
            case "list":
                return LIST;
            
            case "lsub":
                return LSUB;
            
            case "recent":
                return RECENT;
            
            case "search":
                return SEARCH;
            
            case "status":
                return STATUS;
            
            default:
                throw new ImapError.PARSE_ERROR("\"%s\" is not a valid server data type", value);
        }
    }
    
    public StringParameter to_parameter() {
        return new StringParameter(to_string());
    }
    
    public static ServerDataType from_parameter(StringParameter param) throws ImapError {
        return decode(param.value);
    }
}

