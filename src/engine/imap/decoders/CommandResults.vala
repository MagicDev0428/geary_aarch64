/* Copyright 2011 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

public abstract class Geary.Imap.CommandResults {
    public StatusResponse status_response { get; private set; }
    
    public CommandResults(StatusResponse status_response) {
        this.status_response = status_response;
    }
}

