/* Copyright 2011-2012 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

// TODO: This class currently deals with generic email storage as well as IMAP-specific issues; in
// the future, to support other email services, will need to break this up.

private class Geary.Sqlite.Folder : Object, Geary.ReferenceSemantics {
    public const Geary.Email.Field REQUIRED_FOR_DUPLICATE_DETECTION = Geary.Email.Field.PROPERTIES;
    
    [Flags]
    public enum ListFlags {
        NONE = 0,
        PARTIAL_OK,
        INCLUDE_MARKED_FOR_REMOVE,
        EXCLUDING_ID;
        
        public bool is_all_set(ListFlags flags) {
            return (this & flags) == flags;
        }
        
        public bool is_any_set(ListFlags flags) {
            return (this & flags) != 0;
        }
    }
    
    public bool opened { get; private set; default = false; }
    
    protected int manual_ref_count { get; protected set; }
    
    private ImapDatabase db;
    private FolderRow folder_row;
    private Geary.Imap.FolderProperties? properties;
    private MessageTable message_table;
    private MessageLocationTable location_table;
    private ImapMessagePropertiesTable imap_message_properties_table;
    private Geary.FolderPath path;
    
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
    
    public Geary.FolderPath get_path() {
        return path;
    }
    
    public Geary.Imap.FolderProperties? get_properties() {
        // TODO: TBD: alteration/updated signals for folders
        return properties;
    }
    
    internal void update_properties(Geary.Imap.FolderProperties? properties) {
        this.properties = properties;
    }
    
    public async void open_async(bool readonly, Cancellable? cancellable = null) throws Error {
        if (opened)
            throw new EngineError.ALREADY_OPEN("%s already open", to_string());
        
        opened = true;
        
        // Possible some messages were marked for removal in prior session and not properly deleted
        // (for example, if the EXPUNGE message didn't come back before closing the folder, or
        // the app is shut down or crashes) ... folder normalization will take care of messages that
        // are still in folder even if they're marked here, so go ahead and remove them from the
        // location table
        yield location_table.remove_all_marked_for_remove(null, folder_row.id, cancellable);
    }
    
    public async void close_async(Cancellable? cancellable = null) throws Error {
        if (!opened)
            return;
        
        opened = false;
    }
    
    public async int get_email_count_async(Cancellable? cancellable = null) throws Error {
        return yield internal_get_email_count_async(null, false, cancellable);
    }
    
    public async int get_email_count_including_marked_async(Cancellable? cancellable = null)
        throws Error {
        return yield internal_get_email_count_async(null, true, cancellable);
    }
    
    private async int internal_get_email_count_async(Transaction? transaction, bool include_marked,
        Cancellable? cancellable) throws Error {
        check_open();
        
        // TODO: This can be cached and updated when changes occur
        return yield location_table.fetch_count_for_folder_async(transaction, folder_row.id,
            include_marked, cancellable);
    }
    
    public async int get_id_position_async(Geary.EmailIdentifier id, Cancellable? cancellable)
        throws Error {
        check_open();
        
        Transaction transaction = yield db.begin_transaction_async("Folder.get_id_position_async",
            cancellable);
        
        int64 message_id;
        if (!yield location_table.does_ordering_exist_async(transaction, folder_row.id,
            id.ordering, out message_id, cancellable)) {
            return -1;
        }
        
        return yield location_table.fetch_message_position_async(transaction, message_id, folder_row.id,
            cancellable);
    }
    
    public async bool create_email_async(Geary.Email email, Cancellable? cancellable = null)
        throws Error {
        return yield atomic_create_email_async(null, email, cancellable);
    }
    
    // TODO: Need to break out IMAP-specific functionality
    private async int64 search_for_duplicate_async(Transaction transaction, Geary.Email email,
        Cancellable? cancellable) throws Error {
        // if fields not present, then no duplicate can reliably be found
        if (!email.fields.is_all_set(REQUIRED_FOR_DUPLICATE_DETECTION))
            return Sqlite.Row.INVALID_ID;
        
        // See if it already exists; first by UID (which is only guaranteed to be unique in a folder,
        // not account-wide)
        int64 message_id;
        if (yield location_table.does_ordering_exist_async(transaction, folder_row.id,
            email.id.ordering, out message_id, cancellable)) {
            return message_id;
        }
        
        // what's more, actually need all those fields to be available, not merely attempted,
        // to err on the side of safety
        Imap.EmailProperties? imap_properties = (Imap.EmailProperties) email.properties;
        string? internaldate = (imap_properties != null && imap_properties.internaldate != null)
            ? imap_properties.internaldate.original : null;
        long rfc822_size = (imap_properties != null && imap_properties.rfc822_size != null)
            ? imap_properties.rfc822_size.value : -1;
        
        if (String.is_empty(internaldate) || rfc822_size < 0)
            return Sqlite.Row.INVALID_ID;
        
        // reset
        message_id = Sqlite.Row.INVALID_ID;
        
        // look for duplicate in IMAP message properties
        Gee.List<int64?>? duplicate_ids = yield imap_message_properties_table.search_for_duplicates_async(
            transaction, internaldate, rfc822_size, cancellable);
        if (duplicate_ids != null && duplicate_ids.size > 0) {
            if (duplicate_ids.size > 1) {
                debug("Warning: Multiple messages with the same internaldate (%s) and size (%lu) found in %s",
                    internaldate, rfc822_size, to_string());
                message_id = duplicate_ids[0];
            } else if (duplicate_ids.size == 1) {
                message_id = duplicate_ids[0];
            }
        }
        
        return message_id;
    }
    
    // Returns false if the message already exists at the specified position
    private async bool associate_with_folder_async(Transaction transaction, int64 message_id,
        Geary.Email email, Cancellable? cancellable) throws Error {
        // see if an email exists at this position
        MessageLocationRow? location_row = yield location_table.fetch_by_ordering_async(transaction,
            folder_row.id, email.id.ordering, cancellable);
        if (location_row != null)
            return false;
        
        // insert email at supplied position
        location_row = new MessageLocationRow(location_table, Row.INVALID_ID, message_id,
            folder_row.id, email.id.ordering, email.position);
        yield location_table.create_async(transaction, location_row, cancellable);
        
        return true;
    }
    
    private async bool atomic_create_email_async(Transaction? supplied_transaction, Geary.Email email,
        Cancellable? cancellable) throws Error {
        check_open();
        
        Transaction transaction = supplied_transaction ?? yield db.begin_transaction_async(
            "Folder.atomic_create_email_async", cancellable);
        
        // See if this Email is already associated with the folder
        int64 message_id;
        bool associated = yield location_table.does_ordering_exist_async(transaction, folder_row.id,
            email.id.ordering, out message_id, cancellable);
        
        // if duplicate found, associate this email with this folder and merge in any new details
        if (!associated || message_id == Sqlite.Row.INVALID_ID)
            message_id = yield search_for_duplicate_async(transaction, email, cancellable);
        
        // if already associated or a duplicate, merge and/or associate
        if (message_id != Sqlite.Row.INVALID_ID) {
            if (!associated) {
                if (!yield associate_with_folder_async(transaction, message_id, email, cancellable)) {
                    debug("Warning: Unable to associate %s (%lld) with %s", email.id.to_string(), message_id,
                        to_string());
                }
            }
            
            yield merge_email_async(transaction, message_id, email, cancellable);
            
            if (supplied_transaction == null)
                yield transaction.commit_if_required_async(cancellable);
            
            return false;
        }
        
        // not found, so create and associate with this folder
        message_id = yield message_table.create_async(transaction,
            new MessageRow.from_email(message_table, email), cancellable);
        
        // create the message location in the location lookup table
        MessageLocationRow location_row = new MessageLocationRow(location_table, Row.INVALID_ID,
            message_id, folder_row.id, email.id.ordering, email.position);
        yield location_table.create_async(transaction, location_row, cancellable);
        
        // only write out the IMAP email properties if they're supplied and there's something to
        // write out -- no need to create an empty row
        Geary.Imap.EmailProperties? properties = (Geary.Imap.EmailProperties?) email.properties;
        Geary.Imap.EmailFlags? email_flags = (Geary.Imap.EmailFlags?) email.email_flags;
        if (email.fields.is_any_set(Geary.Email.Field.PROPERTIES | Geary.Email.Field.FLAGS)) {
            ImapMessagePropertiesRow properties_row = new ImapMessagePropertiesRow.from_imap_properties(
                imap_message_properties_table, message_id, properties,
                (email_flags != null) ? email_flags.message_flags : null);
            
            yield imap_message_properties_table.create_async(transaction, properties_row, cancellable);
        }
        
        // only commit if not supplied a transaction
        if (supplied_transaction == null)
            yield transaction.commit_async(cancellable);
        
        return true;
    }
    
    public async Gee.List<Geary.Email>? list_email_async(int low, int count,
        Geary.Email.Field required_fields, ListFlags flags, Cancellable? cancellable) throws Error {
        check_open();
        
        Transaction transaction = yield db.begin_transaction_async("Folder.list_email_async",
            cancellable);
        
        int local_count = yield internal_get_email_count_async(transaction,
            flags.is_all_set(ListFlags.INCLUDE_MARKED_FOR_REMOVE), cancellable);
        Geary.Folder.normalize_span_specifiers(ref low, ref count, local_count);
        
        if (count == 0)
            return null;
        
        Gee.List<MessageLocationRow>? list = yield location_table.list_async(transaction,
            folder_row.id, low, count, flags.is_all_set(ListFlags.INCLUDE_MARKED_FOR_REMOVE),
            cancellable);
        
        return yield do_list_email_async(transaction, list, required_fields, flags, cancellable);
    }
    
    public async Gee.List<Geary.Email>? list_email_by_id_async(Geary.EmailIdentifier initial_id,
        int count, Geary.Email.Field required_fields, Folder.ListFlags flags,
        Cancellable? cancellable = null) throws Error {
        if (count == 0 || count == 1) {
            try {
                Geary.Email email = yield fetch_email_async(initial_id, required_fields, flags,
                    cancellable);
                
                Gee.List<Geary.Email> singleton = new Gee.ArrayList<Geary.Email>();
                singleton.add(email);
                
                return singleton;
            } catch (EngineError engine_err) {
                // list_email variants don't return NOT_FOUND or INCOMPLETE_MESSAGE
                if ((engine_err is EngineError.NOT_FOUND) || (engine_err is EngineError.INCOMPLETE_MESSAGE))
                    return null;
                
                throw engine_err;
            }
        }
        
        check_open();
        
        Geary.Imap.UID uid = ((Geary.Imap.EmailIdentifier) initial_id).uid;
        bool excluding_id = flags.is_all_set(ListFlags.EXCLUDING_ID);
        
        Transaction transaction = yield db.begin_transaction_async("Folder.list_email_by_id_async",
            cancellable);
        
        int64 low, high;
        if (count < 0) {
            high = excluding_id ? uid.value - 1 : uid.value;
            low = (count != int.MIN) ? (high + count).clamp(1, uint32.MAX) : -1;
        } else {
            // count > 1
            low = excluding_id ? uid.value + 1 : uid.value;
            high = (count != int.MAX) ? (low + count).clamp(1, uint32.MAX) : -1;
        }
        
        Gee.List<MessageLocationRow>? list = yield location_table.list_ordering_async(transaction,
            folder_row.id, low, high, cancellable);
        
        return yield do_list_email_async(transaction, list, required_fields, flags, cancellable);
    }
    
    private async Gee.List<Geary.Email>? do_list_email_async(Transaction transaction,
        Gee.List<MessageLocationRow>? list, Geary.Email.Field required_fields,
        ListFlags flags, Cancellable? cancellable) throws Error {
        check_open();
        
        if (list == null || list.size == 0)
            return null;
        
        bool partial_ok = flags.is_all_set(ListFlags.PARTIAL_OK);
        bool include_removed = flags.is_all_set(ListFlags.INCLUDE_MARKED_FOR_REMOVE);
        
        // TODO: As this loop involves multiple database operations to form an email, might make
        // sense in the future to launch each async method separately, putting the final results
        // together when all the information is fetched
        Gee.List<Geary.Email> emails = new Gee.ArrayList<Geary.Email>();
        foreach (MessageLocationRow location_row in list) {
            // PROPERTIES and FLAGS are held in separate table from messages, pull from MessageTable
            // only if something is needed from there
            Geary.Email.Field message_fields =
                required_fields.clear(Geary.Email.Field.PROPERTIES | Geary.Email.Field.FLAGS);
            
            // fetch the message itself
            MessageRow? message_row = null;
            if (message_fields != Geary.Email.Field.NONE) {
                message_row = yield message_table.fetch_async(transaction, location_row.message_id,
                    message_fields, cancellable);
                assert(message_row != null);
                
                // only add to the list if the email contains all the required fields (because
                // properties comes out of a separate table, skip this if properties are requested)
                if (!partial_ok && !message_row.fields.fulfills(message_fields))
                    continue;
            }
            
            ImapMessagePropertiesRow? properties = null;
            if (required_fields.is_any_set(Geary.Email.Field.PROPERTIES | Geary.Email.Field.FLAGS)) {
                properties = yield imap_message_properties_table.fetch_async(transaction,
                    location_row.message_id, cancellable);
                if (!partial_ok && properties == null)
                    continue;
            }
            
            Geary.Imap.UID uid = new Geary.Imap.UID(location_row.ordering);
            int position = yield location_row.get_position_async(transaction, include_removed,
                 cancellable);
            if (position == -1) {
                debug("WARNING: Unable to locate position of email during list of %s, dropping",
                    to_string());
                
                continue;
            }
            
            Geary.Imap.EmailIdentifier email_id = new Geary.Imap.EmailIdentifier(uid);
            
            Geary.Email email = (message_row != null)
                ? message_row.to_email(position, email_id)
                : new Geary.Email(position, email_id);
                
            if (properties != null) {
                if (required_fields.require(Geary.Email.Field.PROPERTIES)) {
                    Imap.EmailProperties? email_properties = properties.get_imap_email_properties();
                    if (email_properties != null)
                        email.set_email_properties(email_properties);
                    else if (!partial_ok)
                        continue;
                }
                
                if (required_fields.require(Geary.Email.Field.FLAGS)) {
                    EmailFlags? email_flags = properties.get_email_flags();
                    if (email_flags != null)
                        email.set_flags(email_flags);
                    else if (!partial_ok)
                        continue;
                }
            }
            
            emails.add(email);
        }
        
        return (emails.size > 0) ? emails : null;
    }
    
    public async Geary.Email fetch_email_async(Geary.EmailIdentifier id,
        Geary.Email.Field required_fields, ListFlags flags, Cancellable? cancellable = null) throws Error {
        check_open();
        
        Geary.Imap.UID uid = ((Imap.EmailIdentifier) id).uid;
        bool partial_ok = flags.is_all_set(ListFlags.PARTIAL_OK);
        bool include_removed = flags.is_all_set(ListFlags.INCLUDE_MARKED_FOR_REMOVE);
        
        Transaction transaction = yield db.begin_transaction_async("Folder.fetch_email_async",
            cancellable);
        
        MessageLocationRow? location_row = yield location_table.fetch_by_ordering_async(transaction,
            folder_row.id, uid.value, cancellable);
        if (location_row == null) {
            throw new EngineError.NOT_FOUND("No message with ID %s in folder %s", id.to_string(),
                to_string());
        }
        
        int position = yield location_row.get_position_async(transaction, include_removed, cancellable);
        if (position == -1) {
            throw new EngineError.NOT_FOUND("Unable to determine position of email %s in %s",
                id.to_string(), to_string());
        }
        
        // loopback on perverse case
        if (required_fields == Geary.Email.Field.NONE)
            return new Geary.Email(position, id);
        
        // Only fetch message row if we have fields other than Properties and Flags
        MessageRow? message_row = null;
        if (required_fields.clear(Geary.Email.Field.PROPERTIES | Geary.Email.Field.FLAGS) != 0) {
            message_row = yield message_table.fetch_async(transaction,
                location_row.message_id, required_fields, cancellable);
            if (message_row == null) {
                throw new EngineError.NOT_FOUND("No message with ID %s in folder %s", id.to_string(),
                    to_string());
            }
            
            // see if the message row fulfills everything but properties, which are held in
            // separate table
            if (!partial_ok &&
                !message_row.fields.fulfills(required_fields.clear(Geary.Email.Field.PROPERTIES | Geary.Email.Field.FLAGS))) {
                throw new EngineError.INCOMPLETE_MESSAGE(
                    "Message %s in folder %s only fulfills %Xh fields (required: %Xh)", id.to_string(),
                    to_string(), message_row.fields, required_fields);
            }
        }
        
        ImapMessagePropertiesRow? properties = null;
        if (required_fields.is_any_set(Geary.Email.Field.PROPERTIES | Geary.Email.Field.FLAGS)) {
            properties = yield imap_message_properties_table.fetch_async(transaction,
                location_row.message_id, cancellable);
            if (!partial_ok && properties == null) {
                throw new EngineError.INCOMPLETE_MESSAGE(
                    "Message %s in folder %s does not have PROPERTIES and/or FLAGS fields",
                        id.to_string(), to_string());
            }
        }
        
        Geary.Email email;
        email = message_row != null ? message_row.to_email(position, id) : email =
            new Geary.Email(position, id);
        
        if (properties != null) {
            if (required_fields.require(Geary.Email.Field.PROPERTIES)) {
                Imap.EmailProperties? email_properties = properties.get_imap_email_properties();
                if (email_properties != null) {
                    email.set_email_properties(email_properties);
                } else if (!partial_ok) {
                    throw new EngineError.INCOMPLETE_MESSAGE("Message %s in folder %s does not have PROPERTIES fields",
                        id.to_string(), to_string());
                }
            }
            
            if (required_fields.require(Geary.Email.Field.FLAGS)) {
                EmailFlags? email_flags = properties.get_email_flags();
                if (email_flags != null) {
                    email.set_flags(email_flags);
                } else if (!partial_ok) {
                    throw new EngineError.INCOMPLETE_MESSAGE("Message %s in folder %s does not have FLAGS fields",
                        id.to_string(), to_string());
                }
            }
        }
        
        return email;
    }
    
    public async Geary.Imap.UID? get_earliest_uid_async(Cancellable? cancellable = null) throws Error {
        return yield get_uid_extremes_async(true, cancellable);
    }
    
    public async Geary.Imap.UID? get_latest_uid_async(Cancellable? cancellable = null) throws Error {
        return yield get_uid_extremes_async(false, cancellable);
    }
    
    private async Geary.Imap.UID? get_uid_extremes_async(bool earliest, Cancellable? cancellable)
        throws Error {
        check_open();
        
        int64 ordering = yield location_table.get_ordering_extremes_async(null, folder_row.id,
            earliest, cancellable);
        
        return (ordering >= 1) ? new Geary.Imap.UID(ordering) : null;
    }
    
    public async void remove_single_email_async(Geary.EmailIdentifier email_id,
        Cancellable? cancellable = null) throws Error {
        // TODO: Right now, deleting an email is merely detaching its association with a folder
        // (since it may be located in multiple folders).  This means at some point in the future
        // a vacuum will be required to remove emails that are completely unassociated with the
        // account
        if (!yield location_table.remove_by_ordering_async(null, folder_row.id, email_id.ordering,
            cancellable)) {
            throw new EngineError.NOT_FOUND("Message %s not found in %s", email_id.to_string(),
                to_string());
        }
    }
    
    public async void mark_email_async(
        Gee.List<Geary.EmailIdentifier> to_mark, Geary.EmailFlags? flags_to_add,
        Geary.EmailFlags? flags_to_remove, Cancellable? cancellable = null) throws Error {
        
        Gee.Map<Geary.EmailIdentifier, Geary.EmailFlags> map = yield get_email_flags_async(
            to_mark, cancellable);
        
        foreach (Geary.EmailIdentifier id in map.keys) {
            if (flags_to_add != null)
                foreach (Geary.EmailFlag flag in flags_to_add.get_all())
                    ((Geary.Imap.EmailFlags) map.get(id)).add(flag);
            
            if (flags_to_remove != null)
                foreach (Geary.EmailFlag flag in flags_to_remove.get_all())
                    ((Geary.Imap.EmailFlags) map.get(id)).remove(flag);
        }
        
        yield set_email_flags_async(map, cancellable);
    }
    
    public async Gee.Map<Geary.EmailIdentifier, Geary.EmailFlags> get_email_flags_async(
        Gee.List<Geary.EmailIdentifier> to_get, Cancellable? cancellable) throws Error {
        
        Gee.Map<Geary.EmailIdentifier, Geary.EmailFlags> map = new Gee.HashMap<
            Geary.EmailIdentifier, Geary.EmailFlags>(Hashable.hash_func, Equalable.equal_func);
        
        Transaction transaction = yield db.begin_transaction_async("Folder.get_email_flags_async",
            cancellable);
        
        foreach (Geary.EmailIdentifier id in to_get) {
            MessageLocationRow? location_row = yield location_table.fetch_by_ordering_async(
                transaction, folder_row.id, ((Geary.Imap.EmailIdentifier) id).uid.value,
                cancellable);
            
            if (location_row == null) {
                throw new EngineError.NOT_FOUND("No message with ID %s in folder %s", id.to_string(),
                    to_string());
            }
            
            ImapMessagePropertiesRow? row = yield imap_message_properties_table.fetch_async(
                transaction, location_row.message_id, cancellable);
            if (row == null)
                continue;
            
            EmailFlags? email_flags = row.get_email_flags();
            if (email_flags != null)
                map.set(id, email_flags);
        }
        
        yield transaction.commit_async(cancellable);
        
        return map;
    }
    
    public async void set_email_flags_async(Gee.Map<Geary.EmailIdentifier, 
        Geary.EmailFlags> map, Cancellable? cancellable) throws Error {
        check_open();
        
        Transaction transaction = yield db.begin_transaction_async("Folder.set_email_flags_async",
            cancellable);
        
        foreach (Geary.EmailIdentifier id in map.keys) {
            MessageLocationRow? location_row = yield location_table.fetch_by_ordering_async(
                transaction, folder_row.id, ((Geary.Imap.EmailIdentifier) id).uid.value, cancellable);
            if (location_row == null) {
                throw new EngineError.NOT_FOUND("No message with ID %s in folder %s", id.to_string(),
                    to_string());
            }
            
            Geary.Imap.MessageFlags flags = ((Geary.Imap.EmailFlags) map.get(id)).message_flags;
            
            yield imap_message_properties_table.update_flags_async(transaction, location_row.message_id,
                 flags.serialize(), cancellable);
        }
        
        yield transaction.commit_async(cancellable);
    }
    
    public async bool is_email_present_async(Geary.EmailIdentifier id, out Geary.Email.Field available_fields,
        Cancellable? cancellable = null) throws Error {
        check_open();
        
        Geary.Imap.UID uid = ((Imap.EmailIdentifier) id).uid;
        
        available_fields = Geary.Email.Field.NONE;
        
        Transaction transaction = yield db.begin_transaction_async("Folder.is_email_present",
            cancellable);
        
        MessageLocationRow? location_row = yield location_table.fetch_by_ordering_async(transaction,
            folder_row.id, uid.value, cancellable);
        if (location_row == null)
            return false;
        
        return yield message_table.fetch_fields_async(transaction, location_row.message_id,
            out available_fields, cancellable);
    }
    
    private async void merge_email_async(Transaction transaction, int64 message_id, Geary.Email email,
        Cancellable? cancellable = null) throws Error {
        assert(message_id != Row.INVALID_ID);
        
        // if nothing to merge, nothing to do
        if (email.fields == Geary.Email.Field.NONE)
            return;
        
        // Only merge with MessageTable if has fields applicable to it
        if (email.fields.clear(Geary.Email.Field.PROPERTIES | Geary.Email.Field.FLAGS) != 0) {
            MessageRow? message_row = yield message_table.fetch_async(transaction, message_id, email.fields,
                cancellable);
            assert(message_row != null);
            
            message_row.merge_from_remote(email);
            
            // possible nothing has changed or been added
            if (message_row.fields != Geary.Email.Field.NONE)
                yield message_table.merge_async(transaction, message_row, cancellable);
        }
        
        // update IMAP properties
        if (email.fields.fulfills(Geary.Email.Field.PROPERTIES)) {
            Geary.Imap.EmailProperties properties = (Geary.Imap.EmailProperties) email.properties;
            string? internaldate =
                (properties.internaldate != null) ? properties.internaldate.original : null;
            long rfc822_size =
                (properties.rfc822_size != null) ? properties.rfc822_size.value : -1;
            
            yield imap_message_properties_table.update_properties_async(transaction, message_id,
                internaldate, rfc822_size, cancellable);
        }
        
        // update IMAP flags
        if (email.fields.fulfills(Geary.Email.Field.FLAGS)) {
            string? flags = ((Geary.Imap.EmailFlags) email.email_flags).message_flags.serialize();
            
            yield imap_message_properties_table.update_flags_async(transaction, message_id,
                flags, cancellable);
        }
    }
    
    public async void remove_marked_email_async(Geary.EmailIdentifier id, out bool marked,
        Cancellable? cancellable) throws Error {
        check_open();
        
        Transaction transaction = yield db.begin_transaction_async(
            "Folder.remove_marked_email_async", cancellable);
        
        // Get marked status.
        marked = yield location_table.is_marked_removed_async(transaction, folder_row.id,
            id.ordering, cancellable);
        
        // Detaching email's association with a folder.
        if (!yield location_table.remove_by_ordering_async(transaction, folder_row.id,
            id.ordering, cancellable)) {
            throw new EngineError.NOT_FOUND("Message %s in local store of %s not found",
                id.to_string(), to_string());
        }
        
        yield transaction.commit_async(cancellable);
    }
    
    public async void mark_removed_async(Geary.EmailIdentifier id, bool remove, 
        Cancellable? cancellable) throws Error {
        check_open();
        
        Transaction transaction = yield db.begin_transaction_async("Folder.mark_removed_async",
            cancellable);
        
        yield location_table.mark_removed_async(transaction, folder_row.id, id.ordering,
            remove, cancellable);
        yield transaction.commit_async(cancellable);
    }
    
    public async Gee.Map<Geary.EmailIdentifier, Geary.Email.Field>? list_email_fields_by_id_async(
        Gee.Collection<Geary.EmailIdentifier> ids, Cancellable? cancellable) throws Error {
        check_open();
        
        if (ids.size == 0)
            return null;
        
        Gee.HashMap<Geary.EmailIdentifier, Geary.Email.Field> map = new Gee.HashMap<
            Geary.EmailIdentifier, Geary.Email.Field>(Hashable.hash_func, Equalable.equal_func);
        
        Transaction transaction = yield db.begin_transaction_async("get_email_fields_by_id_async",
            cancellable);
        
        foreach (Geary.EmailIdentifier id in ids) {
            MessageLocationRow? row = yield location_table.fetch_by_ordering_async(transaction,
                folder_row.id, ((Geary.Imap.EmailIdentifier) id).uid.value, cancellable);
            if (row == null)
                continue;
            
            Geary.Email.Field fields;
            if (yield message_table.fetch_fields_async(transaction, row.message_id, out fields,
                cancellable)) {
                map.set(id, fields);
            }
        }
        
        return (map.size > 0) ? map : null;
    }
    
    public string to_string() {
        return path.to_string();
    }
}

