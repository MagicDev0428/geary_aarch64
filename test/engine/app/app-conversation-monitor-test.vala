/*
 * Copyright 2018 Michael Gratton <mike@vee.net>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */


class Geary.App.ConversationMonitorTest : TestCase {


    AccountInformation? account_info = null;
    MockAccount? account = null;
    MockFolder? base_folder = null;
    MockFolder? other_folder = null;


    public ConversationMonitorTest() {
        base("Geary.App.ConversationMonitorTest");
        add_test("start_stop_monitoring", start_stop_monitoring);
        add_test("open_error", open_error);
        add_test("load_single_message", load_single_message);
        add_test("load_multiple_messages", load_multiple_messages);
        add_test("load_related_message", load_related_message);
        add_test("base_folder_message_appended", base_folder_message_appended);
        add_test("base_folder_message_removed", base_folder_message_removed);
        add_test("external_folder_message_appended", external_folder_message_appended);
    }

    public override void set_up() {
        this.account_info = new AccountInformation(
            "account_01",
            File.new_for_path("/tmp"),
            File.new_for_path("/tmp")
        );
        this.account = new MockAccount("test", this.account_info);
        this.base_folder = new MockFolder(
            this.account,
            null,
            new MockFolderRoot("base"),
            SpecialFolderType.NONE,
            null
        );
        this.other_folder = new MockFolder(
            this.account,
            null,
            new MockFolderRoot("other"),
            SpecialFolderType.NONE,
            null
        );
    }

    public void start_stop_monitoring() throws Error {
        ConversationMonitor monitor = new ConversationMonitor(
            this.base_folder, Folder.OpenFlags.NONE, Email.Field.NONE, 10
        );
        Cancellable test_cancellable = new Cancellable();

        this.base_folder.expect_call(
            "open_async",
            { MockObject.int_arg(Folder.OpenFlags.NONE), test_cancellable }
        );
        this.base_folder.expect_call("list_email_by_id_async");
        this.base_folder.expect_call("close_async");

        monitor.start_monitoring_async.begin(
            test_cancellable, (obj, res) => { async_complete(res); }
        );
        monitor.start_monitoring_async.end(async_result());

        monitor.stop_monitoring_async.begin(
            test_cancellable, (obj, res) => { async_complete(res); }
        );
        monitor.stop_monitoring_async.end(async_result());

        this.base_folder.assert_expectations();
    }

    public void open_error() throws Error {
        ConversationMonitor monitor = new ConversationMonitor(
            this.base_folder, Folder.OpenFlags.NONE, Email.Field.NONE, 10
        );

        ExpectedCall open = this.base_folder
            .expect_call("open_async")
            .throws(new EngineError.SERVER_UNAVAILABLE("Mock error"));

        monitor.start_monitoring_async.begin(
            null, (obj, res) => { async_complete(res); }
        );
        try {
            monitor.start_monitoring_async.end(async_result());
            assert_not_reached();
        } catch (Error err) {
            assert_error(open.throw_error, err);
        }

        this.base_folder.assert_expectations();
    }

    public void load_single_message() throws Error {
        Email e1 = setup_email(1);

        Gee.MultiMap<EmailIdentifier,FolderPath> paths =
            new Gee.HashMultiMap<EmailIdentifier,FolderPath>();
        paths.set(e1.id, this.base_folder.path);

        ConversationMonitor monitor = setup_monitor({e1}, paths);

        assert_int(1, monitor.size, "Conversation count");
        assert_non_null(monitor.window_lowest, "Lowest window id");
        assert_equal(e1.id, monitor.window_lowest, "Lowest window id");

        Conversation c1 = Geary.Collection.get_first(monitor.read_only_view);
        assert_equal(e1, c1.get_email_by_id(e1.id), "Email not present in conversation");
    }

    public void load_multiple_messages() throws Error {
        Email e1 = setup_email(1, null);
        Email e2 = setup_email(2, null);
        Email e3 = setup_email(3, null);

        Gee.MultiMap<EmailIdentifier,FolderPath> paths =
            new Gee.HashMultiMap<EmailIdentifier,FolderPath>();
        paths.set(e1.id, this.base_folder.path);
        paths.set(e2.id, this.base_folder.path);
        paths.set(e3.id, this.base_folder.path);

        ConversationMonitor monitor = setup_monitor({e3, e2, e1}, paths);

        assert_int(3, monitor.size, "Conversation count");
        assert_non_null(monitor.window_lowest, "Lowest window id");
        assert_equal(e1.id, monitor.window_lowest, "Lowest window id");
    }

    public void load_related_message() throws Error {
        Email e1 = setup_email(1);
        Email e2 = setup_email(2, e1);

        Gee.MultiMap<EmailIdentifier,FolderPath> paths =
            new Gee.HashMultiMap<EmailIdentifier,FolderPath>();
        paths.set(e1.id, this.other_folder.path);
        paths.set(e2.id, this.base_folder.path);

        Gee.MultiMap<Email,FolderPath> related_paths =
            new Gee.HashMultiMap<Email,FolderPath>();
        related_paths.set(e1, this.other_folder.path);
        related_paths.set(e2, this.base_folder.path);

        ConversationMonitor monitor = setup_monitor({e2}, paths, {related_paths});

        assert_int(1, monitor.size, "Conversation count");
        assert_non_null(monitor.window_lowest, "Lowest window id");
        assert_equal(e2.id, monitor.window_lowest, "Lowest window id");

        Conversation c1 = Geary.Collection.get_first(monitor.read_only_view);
        assert_equal(e1, c1.get_email_by_id(e1.id), "Related email not present in conversation");
        assert_equal(e2, c1.get_email_by_id(e2.id), "In folder not present in conversation");
    }

    public void base_folder_message_appended() throws Error {
        Email e1 = setup_email(1);

        Gee.MultiMap<EmailIdentifier,FolderPath> paths =
            new Gee.HashMultiMap<EmailIdentifier,FolderPath>();
        paths.set(e1.id, this.base_folder.path);

        ConversationMonitor monitor = setup_monitor();
        assert_int(0, monitor.size, "Initial conversation count");

        this.base_folder.expect_call("list_email_by_sparse_id_async")
            .returns_object(new Gee.ArrayList<Email>.wrap({e1}));

        this.account.expect_call("get_special_folder");
        this.account.expect_call("get_special_folder");
        this.account.expect_call("get_special_folder");
        this.account.expect_call("local_search_message_id_async");

        this.account.expect_call("get_containing_folders_async")
            .returns_object(paths);

        this.base_folder.email_appended(new Gee.ArrayList<EmailIdentifier>.wrap({e1.id}));

        wait_for_signal(monitor, "conversations-added");
        this.base_folder.assert_expectations();
        this.account.assert_expectations();

        assert_int(1, monitor.size, "Conversation count");
    }

    public void base_folder_message_removed() throws Error {
        Email e1 = setup_email(1);
        Email e2 = setup_email(2, e1);
        Email e3 = setup_email(3);

        Gee.MultiMap<EmailIdentifier,FolderPath> paths =
            new Gee.HashMultiMap<EmailIdentifier,FolderPath>();
        paths.set(e1.id, this.other_folder.path);
        paths.set(e2.id, this.base_folder.path);
        paths.set(e3.id, this.base_folder.path);

        Gee.MultiMap<Email,FolderPath> e2_related_paths =
            new Gee.HashMultiMap<Email,FolderPath>();
        e2_related_paths.set(e1, this.other_folder.path);
        e2_related_paths.set(e2, this.base_folder.path);

        ConversationMonitor monitor = setup_monitor(
            {e3, e2}, paths, {null, e2_related_paths}
        );
        assert_int(2, monitor.size, "Initial conversation count");
        print("monitor.window_lowest: %s", monitor.window_lowest.to_string());
        assert_equal(e2.id, monitor.window_lowest, "Lowest window id");

        // Removing a message will trigger another async load
        this.base_folder.expect_call("list_email_by_id_async");
        this.account.expect_call("get_containing_folders_async");
        this.base_folder.expect_call("list_email_by_id_async");

        this.base_folder.email_removed(new Gee.ArrayList<EmailIdentifier>.wrap({e2.id}));
        wait_for_signal(monitor, "conversations-removed");
        assert_int(1, monitor.size, "Conversation count");
        assert_equal(e3.id, monitor.window_lowest, "Lowest window id");

        this.base_folder.email_removed(new Gee.ArrayList<EmailIdentifier>.wrap({e3.id}));
        wait_for_signal(monitor, "conversations-removed");
        assert_int(0, monitor.size, "Conversation count");
        assert_null(monitor.window_lowest, "Lowest window id");

        // Close the monitor to cancel the final load so it does not
        // error out during later tests
        this.base_folder.expect_call("close_async");
        monitor.stop_monitoring_async.begin(
            null, (obj, res) => { async_complete(res); }
        );
        monitor.stop_monitoring_async.end(async_result());
    }

    public void external_folder_message_appended() throws Error {
        Email e1 = setup_email(1);
        Email e2 = setup_email(2, e1);
        Email e3 = setup_email(3, e1);

        Gee.MultiMap<EmailIdentifier,FolderPath> paths =
            new Gee.HashMultiMap<EmailIdentifier,FolderPath>();
        paths.set(e1.id, this.base_folder.path);
        paths.set(e2.id, this.base_folder.path);
        paths.set(e3.id, this.other_folder.path);

        Gee.MultiMap<Email,FolderPath> related_paths =
            new Gee.HashMultiMap<Email,FolderPath>();
        related_paths.set(e1, this.base_folder.path);
        related_paths.set(e3, this.other_folder.path);

        ConversationMonitor monitor = setup_monitor({e1}, paths);
        assert_int(1, monitor.size, "Initial conversation count");

        this.other_folder.expect_call("open_async");
        this.other_folder.expect_call("list_email_by_sparse_id_async")
            .returns_object(new Gee.ArrayList<Email>.wrap({e3}));
        this.other_folder.expect_call("list_email_by_sparse_id_async")
            .returns_object(new Gee.ArrayList<Email>.wrap({e3}));
        this.other_folder.expect_call("close_async");

        // ExternalAppendOperation's blacklist check
        this.account.expect_call("get_special_folder");
        this.account.expect_call("get_special_folder");
        this.account.expect_call("get_special_folder");

        /////////////////////////////////////////////////////////
        // First call to expand_conversations_async for e3's refs

        // LocalSearchOperationAppendOperation's blacklist check
        this.account.expect_call("get_special_folder");
        this.account.expect_call("get_special_folder");
        this.account.expect_call("get_special_folder");

        // Search for e1's ref
        this.account.expect_call("local_search_message_id_async")
            .returns_object(related_paths);

        // Search for e2's ref
        this.account.expect_call("local_search_message_id_async");

        //////////////////////////////////////////////////////////
        // Second call to expand_conversations_async for e1's refs

        this.account.expect_call("get_special_folder");
        this.account.expect_call("get_special_folder");
        this.account.expect_call("get_special_folder");
        this.account.expect_call("local_search_message_id_async");

        // Finally, the call to process_email_complete_async

        this.account.expect_call("get_containing_folders_async")
            .returns_object(paths);

        // Should not be added, since it's actually in the base folder
        this.account.email_appended(
            this.base_folder,
            new Gee.ArrayList<EmailIdentifier>.wrap({e2.id})
        );

        // Should be added, since it's an external message
        this.account.email_appended(
            this.other_folder,
            new Gee.ArrayList<EmailIdentifier>.wrap({e3.id})
        );

        wait_for_signal(monitor, "conversations-added");
        this.base_folder.assert_expectations();
        this.other_folder.assert_expectations();
        this.account.assert_expectations();

        assert_int(1, monitor.size, "Conversation count");

        Conversation c1 = Geary.Collection.get_first(monitor.read_only_view);
        assert_int(2, c1.get_count(), "Conversation message count");
        assert_equal(e3, c1.get_email_by_id(e3.id),
                     "Appended email not present in conversation");
    }

    private Email setup_email(int id, Email? references = null) {
        Email email = new Email(new MockEmailIdentifer(id));
        DateTime now = new DateTime.now_local();
        Geary.RFC822.MessageID mid = new Geary.RFC822.MessageID(
            "test%d@localhost".printf(id)
        );

        Geary.RFC822.MessageIDList refs_list = null;
        if (references != null) {
            refs_list = new Geary.RFC822.MessageIDList.single(
                references.message_id
            );
        }
        email.set_send_date(new Geary.RFC822.Date.from_date_time(now));
        email.set_email_properties(new MockEmailProperties(now));
        email.set_full_references(mid, null, refs_list);
        return email;
    }

    private ConversationMonitor
        setup_monitor(Email[] base_folder_email = {},
                      Gee.MultiMap<EmailIdentifier,FolderPath>? paths = null,
                      Gee.MultiMap<Email,FolderPath>[] related_paths = {})
        throws Error {
        ConversationMonitor monitor = new ConversationMonitor(
            this.base_folder, Folder.OpenFlags.NONE, Email.Field.NONE, 10
        );
        Cancellable test_cancellable = new Cancellable();

        /*
         * The process for loading messages looks roughly like this:
         * - load_by_id_async
         *   - base_folder.list_email_by_id_async
         *   - process_email_async
         *     - gets all related messages from listing
         *     - expand_conversations_async
         *       - get_search_folder_blacklist (i.e. account.get_special_folder × 3)
         *       - foreach related: account.local_search_message_id_async
         *       - process_email_async
         *         - process_email_complete_async
         *           - get_containing_folders_async
         */

        this.base_folder.expect_call("open_async");
        ExpectedCall list_call = this.base_folder
            .expect_call("list_email_by_id_async")
            .returns_object(new Gee.ArrayList<Email>.wrap(base_folder_email));

        if (base_folder_email.length > 0) {
            // expand_conversations_async calls
            // Account:get_special_folder() in
            // get_search_folder_blacklist, and the default
            // implementation of that calls get_special_folder.
            this.account.expect_call("get_special_folder");
            this.account.expect_call("get_special_folder");
            this.account.expect_call("get_special_folder");

            Gee.List<RFC822.MessageID> base_email_ids =
                new Gee.ArrayList<RFC822.MessageID>();
            foreach (Email base_email in base_folder_email) {
                base_email_ids.add(base_email.message_id);
            }
                
            int base_i = 0;
            bool has_related = (
                base_folder_email.length == related_paths.length
            );
            bool found_related = false;
            Gee.Set<RFC822.MessageID> seen_ids = new Gee.HashSet<RFC822.MessageID>();
            foreach (Email base_email in base_folder_email) {
                ExpectedCall call =
                    this.account.expect_call("local_search_message_id_async");
                seen_ids.add(base_email.message_id);
                if (has_related && related_paths[base_i] != null) {
                    call.returns_object(related_paths[base_i++]);
                    found_related = true;
                }

                foreach (RFC822.MessageID ancestor in base_email.get_ancestors()) {
                    if (!seen_ids.contains(ancestor) && !base_email_ids.contains(ancestor)) {
                        this.account.expect_call("local_search_message_id_async");
                        seen_ids.add(ancestor);
                    }
                }
            }

            // Second call to expand_conversations_async will be made
            // if any related were loaded
            if (found_related) {
                this.account.expect_call("get_special_folder");
                this.account.expect_call("get_special_folder");
                this.account.expect_call("get_special_folder");

                seen_ids.clear();
                foreach (Gee.MultiMap<Email,FolderPath> related in related_paths) {
                    if (related != null) {
                        foreach (Email email in related.get_keys()) {
                            if (!base_email_ids.contains(email.message_id)) {
                                foreach (RFC822.MessageID ancestor in email.get_ancestors()) {
                                    if (!seen_ids.contains(ancestor)) {
                                        this.account.expect_call("local_search_message_id_async");
                                        seen_ids.add(ancestor);
                                    }
                                }
                            }
                        }
                    }
                }
            }

            ExpectedCall contains =
            this.account.expect_call("get_containing_folders_async");
            if (paths != null) {
                contains.returns_object(paths);
            }
        }

        monitor.start_monitoring_async.begin(
            test_cancellable, (obj, res) => { async_complete(res); }
        );
        monitor.start_monitoring_async.end(async_result());

        if (base_folder_email.length == 0) {
            wait_for_call(list_call);
        } else {
            wait_for_signal(monitor, "conversations-added");
        }

        this.base_folder.assert_expectations();
        this.account.assert_expectations();

        return monitor;
    }

}
