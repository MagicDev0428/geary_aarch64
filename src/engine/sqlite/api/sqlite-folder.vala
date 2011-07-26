/* Copyright 2011 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

// TODO: This class currently deals with generic email storage as well as IMAP-specific issues; in
// the future, to support other email services, will need to break this up.

public class Geary.Sqlite.Folder : Geary.AbstractFolder, Geary.LocalFolder, Geary.Imap.FolderExtensions,
    Geary.ReferenceSemantics {
    protected int manual_ref_count { get; protected set; }
    
    private MailDatabase db;
    private FolderRow folder_row;
    private Geary.Imap.FolderProperties? properties;
    private MessageTable message_table;
    private MessageLocationTable location_table;
    private ImapMessagePropertiesTable imap_message_properties_table;
    private Geary.FolderPath path;
    private bool opened = false;
    
    internal Folder(ImapDatabase db, FolderRow folder_row, Geary.Imap.FolderProperties? properties,
        Geary.FolderPath path) throws Error {
        this.db = db;
        this.folder_row = folder_row;
        this.properties = properties;
        this.path = path;
        
        message_table = db.get_message_table();
        location_table = db.get_message_location_table();
        imap_message_properties_table = db.get_imap_message_properties_table();
    }
    
    private void check_open() throws Error {
        if (!opened)
            throw new EngineError.OPEN_REQUIRED("%s not open", to_string());
    }
    
    public override Geary.FolderPath get_path() {
        return path;
    }
    
    public override Geary.FolderProperties? get_properties() {
        // TODO: TBD: alteration/updated signals for folders
        return properties;
    }
    
    internal void update_properties(Geary.Imap.FolderProperties? properties) {
        this.properties = properties;
    }
    
    public override async void open_async(bool readonly, Cancellable? cancellable = null) throws Error {
        if (opened)
            throw new EngineError.ALREADY_OPEN("%s already open", to_string());
        
        opened = true;
        
        notify_opened(Geary.Folder.OpenState.LOCAL);
    }
    
    public override async void close_async(Cancellable? cancellable = null) throws Error {
        if (!opened)
            return;
        
        opened = false;
        
        notify_closed(CloseReason.FOLDER_CLOSED);
    }
    
    public override async int get_email_count_async(Cancellable? cancellable = null) throws Error {
        check_open();
        
        // TODO: This can be cached and updated when changes occur
        return yield location_table.fetch_count_for_folder_async(folder_row.id, cancellable);
    }
    
    public override async void create_email_async(Geary.Email email, Cancellable? cancellable = null)
        throws Error {
        check_open();
        
        Geary.Imap.EmailIdentifier id = (Geary.Imap.EmailIdentifier) email.id;
        
        // See if it already exists; first by UID (which is only guaranteed to be unique in a folder,
        // not account-wide)
        int64 message_id;
        if (yield location_table.does_ordering_exist_async(folder_row.id, email.location.ordering,
            out message_id, cancellable)) {
            throw new EngineError.ALREADY_EXISTS("Email with UID %s already exists in %s",
                id.uid.to_string(), to_string());
        }
        
        // TODO: The following steps should be atomic
        message_id = yield message_table.create_async(
            new MessageRow.from_email(message_table, email),
            cancellable);
        
        // create the message location in the location lookup table using its UID for the ordering
        // (which fulfills the requirements for the ordering column)
        MessageLocationRow location_row = new MessageLocationRow(location_table, Row.INVALID_ID,
            message_id, folder_row.id, email.location.ordering, email.location.position);
        yield location_table.create_async(location_row, cancellable);
        
        // only write out the IMAP email properties if they're supplied and there's something to
        // write out -- no need to create an empty row
        Geary.Imap.EmailProperties? properties = (Geary.Imap.EmailProperties?) email.properties;
        if (email.fields.fulfills(Geary.Email.Field.PROPERTIES) && properties != null) {
            ImapMessagePropertiesRow properties_row = new ImapMessagePropertiesRow.from_imap_properties(
                imap_message_properties_table, message_id, properties);
            yield imap_message_properties_table.create_async(properties_row, cancellable);
        }
        
        notify_list_appended(yield get_email_count_async(cancellable));
    }
    
    public override async Gee.List<Geary.Email>? list_email_async(int low, int count,
        Geary.Email.Field required_fields, Cancellable? cancellable) throws Error {
        check_open();
        
        normalize_span_specifiers(ref low, ref count, yield get_email_count_async(cancellable));
        
        if (count == 0)
            return null;
        
        Gee.List<MessageLocationRow>? list = yield location_table.list_async(folder_row.id, low,
            count, cancellable);
        
        return yield list_email(list, required_fields, cancellable);
    }
    
    public override async Gee.List<Geary.Email>? list_email_sparse_async(int[] by_position,
        Geary.Email.Field required_fields, Cancellable? cancellable = null) throws Error {
        check_open();
        
        Gee.List<MessageLocationRow>? list = yield location_table.list_sparse_async(folder_row.id,
            by_position, cancellable);
        
        return yield list_email(list, required_fields, cancellable);
    }
    
    public async Gee.List<Geary.Email>? list_email_uid_async(Geary.Imap.UID? low, Geary.Imap.UID? high,
        Geary.Email.Field required_fields, Cancellable? cancellable = null) throws Error {
        check_open();
        
        Gee.List<MessageLocationRow>? list = yield location_table.list_ordering_async(folder_row.id,
            (low != null) ? low.value : 1, (high != null) ? high.value : -1, cancellable);
        
        return yield list_email(list, required_fields, cancellable);
    }
    
    private async Gee.List<Geary.Email>? list_email(Gee.List<MessageLocationRow>? list,
        Geary.Email.Field required_fields, Cancellable? cancellable) throws Error {
        check_open();
        
        if (list == null || list.size == 0)
            return null;
        
        // TODO: As this loop involves multiple database operations to form an email, might make
        // sense in the future to launch each async method separately, putting the final results
        // together when all the information is fetched
        Gee.List<Geary.Email> emails = new Gee.ArrayList<Geary.Email>();
        foreach (MessageLocationRow location_row in list) {
            // fetch the message itself
            MessageRow? message_row = yield message_table.fetch_async(location_row.message_id,
                required_fields, cancellable);
            assert(message_row != null);
            
            // only add to the list if the email contains all the required fields (because
            // properties comes out of a separate table, skip this if properties are requested)
            if (!message_row.fields.fulfills(required_fields.clear(Geary.Email.Field.PROPERTIES)))
                continue;
            
            ImapMessagePropertiesRow? properties = null;
            if (required_fields.require(Geary.Email.Field.PROPERTIES)) {
                properties = yield imap_message_properties_table.fetch_async(location_row.message_id,
                    cancellable);
                if (properties == null)
                    continue;
            }
            
            Geary.Imap.UID uid = new Geary.Imap.UID(location_row.ordering);
            
            Geary.Email email = message_row.to_email(
                new Geary.Imap.EmailLocation(location_row.position, uid),
                new Geary.Imap.EmailIdentifier(uid));
            if (properties != null)
                email.set_email_properties(properties.get_imap_email_properties());
            
            emails.add(email);
        }
        
        return (emails.size > 0) ? emails : null;
    }
    
    public override async Geary.Email fetch_email_async(Geary.EmailIdentifier id,
        Geary.Email.Field required_fields, Cancellable? cancellable = null) throws Error {
        check_open();
        
        Geary.Imap.UID uid = ((Imap.EmailIdentifier) id).uid;
        
        MessageLocationRow? location_row = yield location_table.fetch_by_ordering_async(folder_row.id,
            uid.value, cancellable);
        if (location_row == null) {
            throw new EngineError.NOT_FOUND("No message with ID %s in folder %s", id.to_string(),
                to_string());
        }
        
        MessageRow? message_row = yield message_table.fetch_async(location_row.message_id,
            required_fields, cancellable);
        if (message_row == null) {
            throw new EngineError.NOT_FOUND("No message with ID %s in folder %s", id.to_string(),
                to_string());
        }
        
        // see if the message row fulfills everything but properties, which are held in
        // separate table
        if (!message_row.fields.fulfills(required_fields.clear(Geary.Email.Field.PROPERTIES))) {
            throw new EngineError.INCOMPLETE_MESSAGE(
                "Message %s in folder %s only fulfills %Xh fields", id.to_string(), to_string(),
                message_row.fields);
        }
        
        ImapMessagePropertiesRow? properties = null;
        if (required_fields.require(Geary.Email.Field.PROPERTIES)) {
            properties = yield imap_message_properties_table.fetch_async(location_row.message_id,
                cancellable);
            if (properties == null) {
                throw new EngineError.INCOMPLETE_MESSAGE(
                    "Message %s in folder %s does not have PROPERTIES field", id.to_string(),
                        to_string());
            }
        }
        
        // TODO: Would be helpful if proper position was known
        Geary.Email email = message_row.to_email(
            new Geary.Imap.EmailLocation(location_row.position, uid), id);
        if (properties != null)
            email.set_email_properties(properties.get_imap_email_properties());
        
        return email;
    }
    
    public async Geary.Imap.UID? get_earliest_uid_async(Cancellable? cancellable = null) throws Error {
        check_open();
        
        int64 ordering = yield location_table.get_earliest_ordering_async(folder_row.id, cancellable);
        
        return (ordering >= 1) ? new Geary.Imap.UID(ordering) : null;
    }
    
    public override async void remove_email_async(Geary.Email email, Cancellable? cancellable = null)
        throws Error {
        check_open();
        
        // TODO: Right now, deleting an email is merely detaching its association with a folder
        // (since it may be located in multiple folders).  This means at some point in the future
        // a vacuum will be required to remove emails that are completely unassociated with the
        // account
        Geary.Imap.UID? uid = ((Geary.Imap.EmailIdentifier) email.id).uid;
        if (uid == null)
            throw new EngineError.NOT_FOUND("UID required to delete local email");
        
        yield location_table.remove_by_ordering_async(folder_row.id, uid.value, cancellable);
        
        // TODO: Notify of changes
    }
    
    public async bool is_email_present(Geary.EmailIdentifier id, out Geary.Email.Field available_fields,
        Cancellable? cancellable = null) throws Error {
        check_open();
        
        Geary.Imap.UID uid = ((Imap.EmailIdentifier) id).uid;
        
        available_fields = Geary.Email.Field.NONE;
        
        MessageLocationRow? location_row = yield location_table.fetch_by_ordering_async(folder_row.id,
            uid.value, cancellable);
        if (location_row == null)
            return false;
        
        return yield message_table.fetch_fields_async(location_row.message_id, out available_fields,
            cancellable);
    }
    
    public async bool is_email_associated_async(Geary.Email email, Cancellable? cancellable = null)
        throws Error {
        check_open();
        
        int64 message_id;
        return yield location_table.does_ordering_exist_async(folder_row.id,
            ((Geary.Imap.EmailIdentifier) email.id).uid.value, out message_id, cancellable);
    }
    
    public async void update_email_async(Geary.Email email, bool duplicate_okay,
        Cancellable? cancellable = null) throws Error {
        check_open();
        
        Geary.Imap.EmailLocation location = (Geary.Imap.EmailLocation) email.location;
        Geary.Imap.EmailIdentifier id = (Geary.Imap.EmailIdentifier) email.id;
        
        // See if the message can be identified in the folder (which both reveals association and
        // a message_id that can be used for a merge; note that this works without a Message-ID)
        int64 message_id;
        bool associated = yield location_table.does_ordering_exist_async(folder_row.id,
            id.uid.value, out message_id, cancellable);
        
        // If working around the lack of a Message-ID and not associated with this folder, treat
        // this operation as a create; otherwise, since a folder-association is determined, do
        // a merge
        if (email.message_id == null) {
            if (!associated) {
                if (!duplicate_okay)
                    throw new EngineError.INCOMPLETE_MESSAGE("No Message-ID");
                
                yield create_email_async(email, cancellable);
            } else {
                yield merge_email_async(message_id, email, cancellable);
            }
            
            return;
        }
        
        // If not associated, find message with matching Message-ID
        if (!associated) {
            Gee.List<int64?>? list = yield message_table.search_message_id_async(email.message_id,
                cancellable);
            
            // If none found, this operation is a create
            if (list == null || list.size == 0) {
                yield create_email_async(email, cancellable);
                
                return;
            }
            
            // Too many found turns this operation into a create
            if (list.size != 1) {
                yield create_email_async(email, cancellable);
                
                return;
            }
            
            message_id = list[0];
        }
        
        // Found a message.  If not associated with this folder, associate now.
        // TODO: Need to lock the database during this operation, as these steps should be atomic.
        if (!associated) {
            // see if an email exists at this position
            MessageLocationRow? location_row = yield location_table.fetch_async(folder_row.id,
                location.position);
            if (location_row != null) {
                throw new EngineError.ALREADY_EXISTS("Email already exists at position %d in %s",
                    email.location.position, to_string());
            }
            
            // insert email at supplied position
            location_row = new MessageLocationRow(location_table, Row.INVALID_ID, message_id,
                folder_row.id, id.uid.value, location.position);
            yield location_table.create_async(location_row, cancellable);
        }
        
        // Merge any new information with the existing message in the local store
        yield merge_email_async(message_id, email, cancellable);
        
        // Done.
    }
    
    // TODO: The database should be locked around this method, as it should be atomic.
    private async void merge_email_async(int64 message_id, Geary.Email email,
        Cancellable? cancellable = null) throws Error {
        assert(message_id != Row.INVALID_ID);
        
        // if nothing to merge, nothing to do
        if (email.fields == Geary.Email.Field.NONE)
            return;
        
        MessageRow? message_row = yield message_table.fetch_async(message_id, email.fields,
            cancellable);
        assert(message_row != null);
        
        message_row.merge_from_network(email);
        
        // possible nothing has changed or been added
        if (message_row.fields != Geary.Email.Field.NONE)
            yield message_table.merge_async(message_row, cancellable);
            
        // update IMAP properties
        if (email.fields.fulfills(Geary.Email.Field.PROPERTIES)) {
            Geary.Imap.EmailProperties properties = (Geary.Imap.EmailProperties) email.properties;
            string? internaldate =
                (properties.internaldate != null) ? properties.internaldate.original : null;
            long rfc822_size =
                (properties.rfc822_size != null) ? properties.rfc822_size.value : -1;
            
            yield imap_message_properties_table.update_async(message_id, properties.flags.serialize(),
                internaldate, rfc822_size, cancellable);
        }
    }
}

