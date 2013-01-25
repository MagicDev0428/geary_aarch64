/* Copyright 2011-2012 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

public class Geary.Imap.StatusResponse : ServerResponse {
    public Status status { get; private set; }
    public ResponseCode? response_code { get; private set; }
    public string? text { get; private set; }
    
    private StatusResponse() {
    }
    
    public StatusResponse.reconstitute(RootParameters root) throws ImapError {
        base.reconstitute(root);
        
        status = Status.from_parameter(get_as_string(1));
        response_code = get(2) as ResponseCode;
        text = (response_code != null) ? flatten_to_text(3) : flatten_to_text(2);
    }
    
    private string? flatten_to_text(int start_index) throws ImapError {
        StringBuilder builder = new StringBuilder();
        
        while (start_index < get_count()) {
            StringParameter? strparam = get(start_index) as StringParameter;
            if (strparam != null) {
                builder.append(strparam.value);
                if (start_index < (get_count() - 1))
                    builder.append_c(' ');
            }
            
            start_index++;
        }
        
        return !String.is_empty(builder.str) ? builder.str : null;
    }
}

