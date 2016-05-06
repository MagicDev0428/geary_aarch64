/* Copyright 2016 Software Freedom Conservancy Inc.
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution.
 */

public abstract class Geary.FolderProperties : BaseObject {
    public const string PROP_NAME_EMAIL_TOTAL = "email-total";
    public const string PROP_NAME_EMAIL_UNREAD = "email-unread";
    public const string PROP_NAME_HAS_CHILDREN = "has-children";
    public const string PROP_NAME_SUPPORTS_CHILDREN = "supports-children";
    public const string PROP_NAME_IS_OPENABLE = "is-openable";
    public const string PROP_NAME_IS_LOCAL_ONLY = "is-local-only";
    public const string PROP_NAME_IS_VIRTUAL = "is-virtual";
    
    /**
     * The total count of email in the {@link Folder}.
     */
    public int email_total { get; protected set; }
    
    /**
     * The total count of unread email in the {@link Folder}.
     */
    public int email_unread { get; protected set; }
    
    /**
     * Returns a {@link Trillian} indicating if this {@link Folder} has children.
     *
     * has_children == {@link Trillian.TRUE} implies {@link supports_children} == Trilian.TRUE.
     */
    public Trillian has_children { get; protected set; }
    
    /**
     * Returns a {@link Trillian} indicating if this {@link Folder} can parent new children
     * {@link Folder}s.
     *
     * This does ''not'' mean creating a sub-folder is guaranteed to succeed.
     */
    public Trillian supports_children { get; protected set; }
    
    /**
     * Returns a {@link Trillian} indicating if {@link Folder.open_async} can succeed remotely.
     */
    public Trillian is_openable { get; protected set; }
    
    /**
     * Returns true if the {@link Folder} is local-only, that is, has no remote folder backing
     * it.
     *
     * Note that this doesn't mean there's no network aspect to the Folder.  For example, an Outbox
     * may present itself as a Folder but the network backing (SMTP) has nothing that resembles
     * a Folder interface.
     */
    public bool is_local_only { get; private set; }
    
    /**
     * Returns true if the {@link Folder} is virtual, that is, it is either generated by some
     * external criteria and/or is aggregating the content of other Folders.
     *
     * In general, virtual folders cannot be the destination Folder for operations like move and
     * copy.
     */
    public bool is_virtual { get; private set; }
    
    /**
     * True if the {@link Folder} offers the {@link FolderSupport.Create} interface but is
     * guaranteed not to return a {@link EmailIdentifier}, even if
     * {@link FolderSupport.Create.create_email_async} succeeds.
     *
     * This is for IMAP servers that don't support UIDPLUS.  Most servers support UIDPLUS, so this
     * will usually be false.
     */
    public bool create_never_returns_id { get; protected set; }
    
    protected FolderProperties(int email_total, int email_unread, Trillian has_children,
        Trillian supports_children, Trillian is_openable, bool is_local_only, bool is_virtual,
        bool create_never_returns_id) {
        this.email_total = email_total;
        this.email_unread = email_unread;
        this.has_children = has_children;
        this.supports_children = supports_children;
        this.is_openable = is_openable;
        this.is_local_only = is_local_only;
        this.is_virtual = is_virtual;
        this.create_never_returns_id = create_never_returns_id;
    }
}

