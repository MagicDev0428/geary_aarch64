/* Copyright 2011-2012 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

public class Geary.RFC822.Message : Object {
    private const string DEFAULT_ENCODING = "UTF8";
    
    public RFC822.MailboxAddress? sender { get; private set; default = null; }
    public RFC822.MailboxAddresses? from { get; private set; default = null; }
    public RFC822.MailboxAddresses? to { get; private set; default = null; }
    public RFC822.MailboxAddresses? cc { get; private set; default = null; }
    public RFC822.MailboxAddresses? bcc { get; private set; default = null; }
    public RFC822.MessageID? in_reply_to { get; private set; default = null; }
    public RFC822.MessageIDList? references { get; private set; default = null; }
    public RFC822.Subject? subject { get; private set; default = null; }
    public string? mailer { get; private set; default = null; }
    
    private GMime.Message message;
    
    public Message(Full full) throws RFC822Error {
        GMime.Parser parser = new GMime.Parser.with_stream(
            new GMime.StreamMem.with_buffer(full.buffer.get_array()));
        
        message = parser.construct_message();
        if (message == null)
            throw new RFC822Error.INVALID("Unable to parse RFC 822 message");
        
        stock_from_gmime();
    }
    
    public Message.from_parts(Header header, Text body) throws RFC822Error {
        GMime.StreamCat stream_cat = new GMime.StreamCat();
        stream_cat.add_source(new GMime.StreamMem.with_buffer(header.buffer.get_array()));
        stream_cat.add_source(new GMime.StreamMem.with_buffer(body.buffer.get_array()));
        
        GMime.Parser parser = new GMime.Parser.with_stream(stream_cat);
        message = parser.construct_message();
        if (message == null)
            throw new RFC822Error.INVALID("Unable to parse RFC 822 message");
        
        stock_from_gmime();
    }

    public Message.from_composed_email(Geary.ComposedEmail email) {
        message = new GMime.Message(true);
        
        // Required headers
        assert(email.from.size > 0);
        sender = email.from[0];
        message.set_sender(sender.to_rfc822_string());
        message.set_date((time_t) email.date.to_unix(),
            (int) (email.date.get_utc_offset() / TimeSpan.HOUR));
        
        // Optional headers
        if (email.to != null) {
            to = email.to;
            foreach (RFC822.MailboxAddress mailbox in email.to)
                message.add_recipient(GMime.RecipientType.TO, mailbox.name, mailbox.address);
        }
        
        if (email.cc != null) {
            cc = email.cc;
            foreach (RFC822.MailboxAddress mailbox in email.cc)
                message.add_recipient(GMime.RecipientType.CC, mailbox.name, mailbox.address);
        }

        if (email.bcc != null) {
            bcc = email.bcc;
            foreach (RFC822.MailboxAddress mailbox in email.bcc)
                message.add_recipient(GMime.RecipientType.BCC, mailbox.name, mailbox.address);
        }

        if (email.in_reply_to != null) {
            in_reply_to = email.in_reply_to;
            message.set_header("In-Reply-To", email.in_reply_to.value);
        }
        
        if (email.references != null) {
            references = email.references;
            message.set_header("References", email.references.to_rfc822_string());
        }
        
        if (email.subject != null) {
            subject = email.subject;
            message.set_subject(email.subject.value);
        }

        // User-Agent
        if (!Geary.String.is_empty(email.mailer)) {
            mailer = email.mailer;
            message.set_header("X-Mailer", email.mailer);
        }

        // Body: text format (optional)
        GMime.Part? body_text = null;
        if (email.body_text != null) {
            GMime.DataWrapper content = new GMime.DataWrapper.with_stream(
                new GMime.StreamMem.with_buffer(email.body_text.buffer.get_array()),
                GMime.ContentEncoding.DEFAULT);
            
            body_text = new GMime.Part();
            body_text.set_content_type(new GMime.ContentType.from_string("text/plain; charset=utf-8"));
            body_text.set_content_object(content);
        }
        
        // Body: HTML format (also optional)
        GMime.Part? body_html = null;
        if (email.body_html != null) {
            GMime.DataWrapper content = new GMime.DataWrapper.with_stream(
                new GMime.StreamMem.with_buffer(email.body_html.buffer.get_array()),
                GMime.ContentEncoding.DEFAULT);
            
            body_html = new GMime.Part();
            body_html.set_content_type(new GMime.ContentType.from_string("text/html; charset=utf-8"));
            body_html.set_content_object(content);
        }
        
        // Setup body depending on what MIME components were filled out.
        if (body_text != null && body_html != null) {
            GMime.Multipart multipart = new GMime.Multipart.with_subtype("alternative");
            multipart.add(body_text);
            multipart.add(body_html);
            message.set_mime_part(multipart);
        } else if (body_text != null) {
            message.set_mime_part(body_text);
        } else if (body_html != null) {
            message.set_mime_part(body_html);
        }
    }

    // Makes a copy of the given message without the BCC fields. This is used for sending the email
    // without sending the BCC headers to all recipients.
    public Message.without_bcc(Message email) {
        // Required headers.
        message = new GMime.Message(true);
        sender = email.sender;
        message.set_sender(email.message.get_sender());
        message.set_date_as_string(email.message.get_date_as_string());

        // Optional headers.
        if (email.to != null) {
            to = email.to;
            foreach (RFC822.MailboxAddress mailbox in email.to)
                message.add_recipient(GMime.RecipientType.TO, mailbox.name, mailbox.address);
        }

        if (email.cc != null) {
            cc = email.cc;
            foreach (RFC822.MailboxAddress mailbox in email.cc)
                message.add_recipient(GMime.RecipientType.CC, mailbox.name, mailbox.address);
        }

        if (email.in_reply_to != null) {
            in_reply_to = email.in_reply_to;
            message.set_header("In-Reply-To", email.in_reply_to.value);
        }

        if (email.references != null) {
            references = email.references;
            message.set_header("References", email.references.to_rfc822_string());
        }

        if (email.subject != null) {
            subject = email.subject;
            message.set_subject(email.subject.value);
        }

        // User-Agent
        if (!Geary.String.is_empty(email.mailer)) {
            mailer = email.mailer;
            message.set_header("X-Mailer", email.mailer);
        }

        // Setup body depending on what MIME components were filled out.
        message.set_mime_part(email.message.get_mime_part());
    }

    private void stock_from_gmime() {
        from = new RFC822.MailboxAddresses.from_rfc822_string(message.get_sender());
        if (from.size == 0) {
            from = null;
        } else {
            // sender is defined as first From address, from better or worse
            sender = from[0];
        }
        
        Gee.List<RFC822.MailboxAddress>? converted = convert_gmime_address_list(
            message.get_recipients(GMime.RecipientType.TO));
        if (converted != null && converted.size > 0)
            to = new RFC822.MailboxAddresses(converted);
        
        converted = convert_gmime_address_list(message.get_recipients(GMime.RecipientType.CC));
        if (converted != null && converted.size > 0)
            cc = new RFC822.MailboxAddresses(converted);
        
        converted = convert_gmime_address_list(message.get_recipients(GMime.RecipientType.BCC));
        if (converted != null && converted.size > 0)
            bcc = new RFC822.MailboxAddresses(converted);
        
        if (!String.is_empty(message.get_subject()))
            subject = new RFC822.Subject.decode(message.get_subject());
    }
    
    private Gee.List<RFC822.MailboxAddress>? convert_gmime_address_list(InternetAddressList? addrlist) {
        if (addrlist == null || addrlist.length() == 0)
            return null;
        
        Gee.List<RFC822.MailboxAddress>? converted = new Gee.ArrayList<RFC822.MailboxAddress>();
        
        int length = addrlist.length();
        for (int ctr = 0; ctr < length; ctr++) {
            InternetAddress addr = addrlist.get_address(ctr);
            
            InternetAddressMailbox? mbox_addr = addr as InternetAddressMailbox;
            if (mbox_addr != null) {
                converted.add(new RFC822.MailboxAddress(mbox_addr.get_name(), mbox_addr.get_addr()));
                
                continue;
            }
            
            InternetAddressGroup? group = addr as InternetAddressGroup;
            if (group != null) {
                Gee.List<RFC822.MailboxAddress>? grouplist = convert_gmime_address_list(
                    group.get_members());
                if (grouplist != null)
                    converted.add_all(grouplist);
                
                continue;
            }
            
            warning("Unknown InternetAddress in list: %s", addr.get_type().name());
        }
        
        return (converted.size > 0) ? converted : null;
    }
    
    public Gee.List<RFC822.MailboxAddress>? get_recipients() {
        Gee.List<RFC822.MailboxAddress> addrs = new Gee.ArrayList<RFC822.MailboxAddress>();
        
        if (to != null)
            addrs.add_all(to.get_all());
        
        if (cc != null)
            addrs.add_all(cc.get_all());
        
        if (bcc != null)
            addrs.add_all(bcc.get_all());
        
        return (addrs.size > 0) ? addrs : null;
    }
    
    public Geary.Memory.AbstractBuffer get_body_rfc822_buffer() {
        return new Geary.Memory.StringBuffer(message.to_string());
    }
    
    public Geary.Memory.AbstractBuffer get_first_mime_part_of_content_type(string content_type)
        throws RFC822Error {
        // search for content type starting from the root
        GMime.Part? part = find_first_mime_part(message.get_mime_part(), content_type);
        if (part == null) {
            throw new RFC822Error.NOT_FOUND("Could not find a MIME part with content-type %s",
                content_type);
        }
        
        // convert payload to a buffer
        return mime_part_to_memory_buffer(part, true);
    }

    private GMime.Part? find_first_mime_part(GMime.Object current_root, string content_type) {
        // descend looking for the content type in a GMime.Part
        GMime.Multipart? multipart = current_root as GMime.Multipart;
        if (multipart != null) {
            int count = multipart.get_count();
            for (int ctr = 0; ctr < count; ctr++) {
                GMime.Part? child_part = find_first_mime_part(multipart.get_part(ctr), content_type);
                if (child_part != null)
                    return child_part;
            }
        }

        GMime.Part? part = current_root as GMime.Part;
        if (part != null && part.get_content_type().to_string() == content_type &&
            part.get_disposition() != "attachment") {
            return part;
        }

        return null;
    }

    internal Gee.List<GMime.Part> get_attachments() throws RFC822Error {
        Gee.List<GMime.Part> attachments = new Gee.ArrayList<GMime.Part>();
        find_attachments( ref attachments, message.get_mime_part() );
        return attachments;
    }

    private void find_attachments(ref Gee.List<GMime.Part> attachments, GMime.Object root)
        throws RFC822Error {

        // If this is a multipart container, dive into each of its children.
        if (root is GMime.Multipart) {
            GMime.Multipart multipart = root as GMime.Multipart;
            int count = multipart.get_count();
            for (int i = 0; i < count; ++i) {
                find_attachments(ref attachments, multipart.get_part(i));
            }
            return;
        }

        // Otherwise see if it has a content disposition of "attachment."
        if (root is GMime.Part && root.get_disposition() == "attachment") {
            attachments.add(root as GMime.Part);
        }
    }

    private Geary.Memory.AbstractBuffer mime_part_to_memory_buffer(GMime.Part part,
        bool to_utf8 = false) throws RFC822Error {

        GMime.DataWrapper? wrapper = part.get_content_object();
        if (wrapper == null) {
            throw new RFC822Error.INVALID("Could not get the content wrapper for content-type %s",
                part.get_content_type().to_string());
        }
        
        ByteArray byte_array = new ByteArray();
        GMime.StreamMem stream = new GMime.StreamMem.with_byte_array(byte_array);
        stream.set_owner(false);
        
        // Convert encoding to UTF-8.
        GMime.StreamFilter stream_filter = new GMime.StreamFilter(stream);
        if (to_utf8) {
            string? charset = part.get_content_type_parameter("charset");
            if (charset == null)
                charset = DEFAULT_ENCODING;
            stream_filter.add(new GMime.FilterCharset(charset, "UTF8"));
        }

        wrapper.write_to_stream(stream_filter);
        
        return new Geary.Memory.Buffer(byte_array.data, byte_array.len);
    }

    public string to_string() {
        return message.to_string();
    }
}

