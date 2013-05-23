/* Copyright 2013 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution.
 */

/**
 * An untagged server response that includes status and well-formed response codes, usually
 * supplying important information or error codes via a {@link ResponseCodeType} and
 * {@link ResponseCode}.
 *
 * See [[http://tools.ietf.org/html/rfc3501#section-7.1]] for more information.
 */

public class Geary.Imap.CodedStatusResponse : StatusResponse {
    public ResponseCodeType response_code_type { get; private set; }
    public ResponseCode response_code { get; private set; }
    
    public CodedStatusResponse(Tag tag, Status status, ResponseCodeType response_code_type,
        ResponseCode response_code) {
        base (tag, status);
        
        this.response_code_type = response_code_type;
        this.response_code = response_code;
    }
    
    /**
     * Converts the {@link RootParameters} into a {@link CodedStatusResponse}.
     *
     * The supplied root is "stripped" of its children.  This may happen even if an exception is
     * thrown.  It's recommended to use {@link is_coded_status_response} prior to this call.
     */
    public CodedStatusResponse.migrate(RootParameters root) throws ImapError {
        base.migrate(root);
        
        if (tag.is_tagged()) {
            throw new ImapError.INVALID("Not a CodedStatusResponse: tagged response: %s",
                root.to_string());
        }
        
        if (status != Status.OK)
            throw new ImapError.INVALID("Not a CodedStatusResponse: not OK: %s", root.to_string());
        
        ResponseCode? as_response_code = get(2) as ResponseCode;
        if (as_response_code == null) {
            throw new ImapError.INVALID("Not a CodedStatusResponse: no response code: %s",
                root.to_string());
        }
        
        response_code = as_response_code;
        response_code_type = ResponseCodeType.from_parameter(response_code.get_as_string(0));
    }
    
    /**
     * Returns true if {@link RootParameters} is an untagged {@link StatusResponse} with a
     * {@link Status} of OK and a valid {@link ResponseCode} and {@link ResponseCodeType}.
     */
    public static bool is_coded_status_response(RootParameters root) {
        Tag? tag = root.get_tag();
        if (tag == null || tag.is_tagged())
            return false;
        
        try {
            if (Status.from_parameter(root.get_as_string(1)) != Status.OK)
                return false;
            
            ResponseCode? response_code = root.get(2) as ResponseCode;
            if (response_code == null)
                return false;
            
            ResponseCodeType.from_parameter(response_code.get_as_string(0));
        } catch (ImapError err) {
            return false;
        }
        
        return is_status_response(root);
    }
    
    /**
     * Converts the {@link ResponseCode} into a UIDNEXT {@link UID}, if possible.
     *
     * @throws ImapError.INVALID if not UIDNEXT.
     */
    public UID get_uid_next() throws ImapError {
        if (response_code_type != ResponseCodeType.UIDNEXT)
            throw new ImapError.INVALID("Not UIDNEXT: %s", to_string());
        
        return new UID(response_code.get_as_string(1).as_int());
    }
    
    /**
     * Converts the {@link ResponseCode} into a {@link UIDValidity}, if possible.
     *
     * @throws ImapError.INVALID if not UIDVALIDITY.
     */
    public UIDValidity get_uid_validity() throws ImapError {
        if (response_code_type != ResponseCodeType.UIDVALIDITY)
            throw new ImapError.INVALID("Not UIDVALIDITY: %s", to_string());
        
        return new UIDValidity(response_code.get_as_string(1).as_int());
    }
    
    /**
     * Converts the {@link ResponseCode} into an UNSEEN value, if possible.
     *
     * @throws ImapError.INVALID if not UNSEEN.
     */
    public int get_unseen() throws ImapError {
        if (response_code_type != ResponseCodeType.UNSEEN)
            throw new ImapError.INVALID("Not UNSEEN: %s", to_string());
        
        return response_code.get_as_string(1).as_int(0, int.MAX);
    }
    
    /**
     * Converts the {@link ResponseCode} into PERMANENTFLAGS {@link MessageFlags}, if possible.
     *
     * @throws ImapError.INVALID if not PERMANENTFLAGS.
     */
    public MessageFlags get_permanent_flags() throws ImapError {
        if (response_code_type != ResponseCodeType.PERMANENT_FLAGS)
            throw new ImapError.INVALID("Not PERMANENTFLAGS: %s", to_string());
        
        return MessageFlags.from_list(response_code.get_as_list(1));
    }
}

