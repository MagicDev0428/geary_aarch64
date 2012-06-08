/* Copyright 2011-2012 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

public class Geary.Attachment {
    public const Email.Field REQUIRED_FIELDS = Email.Field.HEADER | Email.Field.BODY;

    public string filename { get; private set; }
    public string filepath { get; private set; }
    public string mime_type { get; private set; }
    public int64 filesize { get; private set; }
    public int64 id { get; private set; }

    internal Attachment(File data_dir, string filename, string mime_type, int64 filesize,
        int64 message_id, int64 attachment_id) {

        this.filename = filename;
        this.mime_type = mime_type;
        this.filesize = filesize;
        this.filepath = get_path(data_dir, message_id, attachment_id, filename);
        this.id = attachment_id;
    }

    internal static string get_path(File data_dir, int64 message_id, int64 attachment_id,
        string filename) {
        return "%s/attachments/%lld/%lld/%s".printf(data_dir.get_path(), message_id, attachment_id,
            filename);
    }
}

