/* Copyright 2011-2012 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

public enum Geary.Smtp.Command {
    HELO,
    EHLO,
    QUIT,
    HELP,
    NOOP,
    RSET,
    AUTH,
    MAIL,
    RCPT,
    DATA;
    
    public string serialize() {
        switch (this) {
            case HELO:
                return "helo";
            
            case EHLO:
                return "ehlo";
            
            case QUIT:
                return "quit";
            
            case HELP:
                return "help";
            
            case NOOP:
                return "noop";
            
            case RSET:
                return "rset";
            
            case AUTH:
                return "auth";
            
            case MAIL:
                return "mail";
            
            case RCPT:
                return "rcpt";
            
            case DATA:
                return "data";
            
            default:
                assert_not_reached();
        }
    }
    
    public static Command deserialize(string str) throws SmtpError {
        switch (str.down()) {
            case "helo":
                return HELO;
            
            case "ehlo":
                return EHLO;
            
            case "quit":
                return QUIT;
            
            case "help":
                return HELP;
            
            case "noop":
                return NOOP;
            
            case "rset":
                return RSET;
            
            case "auth":
                return AUTH;
            
            case "mail":
                return MAIL;
            
            case "rcpt":
                return RCPT;
            
            case "data":
                return DATA;
            
            default:
                throw new SmtpError.PARSE_ERROR("Unknown command \"%s\"", str);
        }
    }
}

