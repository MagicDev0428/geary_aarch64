/* Copyright 2011-2012 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

// Draws the main toolbar.
public class MainToolbar : Gtk.Box {
    private Gtk.Toolbar toolbar;
    public FolderMenu copy_folder_menu { get; private set; }
    public FolderMenu move_folder_menu { get; private set; }

    public MainToolbar() {
        Object(orientation: Gtk.Orientation.VERTICAL, spacing: 0);

        Gtk.Builder builder = GearyApplication.instance.create_builder("toolbar.glade");
        toolbar = builder.get_object("toolbar") as Gtk.Toolbar;

        // Setup each of the normal toolbar buttons.
        set_toolbutton_action(builder, GearyController.ACTION_NEW_MESSAGE);
        set_toolbutton_action(builder, GearyController.ACTION_REPLY_TO_MESSAGE);
        set_toolbutton_action(builder, GearyController.ACTION_REPLY_ALL_MESSAGE);
        set_toolbutton_action(builder, GearyController.ACTION_FORWARD_MESSAGE);
        set_toolbutton_action(builder, GearyController.ACTION_DELETE_MESSAGE);

        // Setup the folder menus (move/copy).
        Gtk.ToggleToolButton copy_menu_button = set_toolbutton_action(builder,
            GearyController.ACTION_COPY_MENU) as Gtk.ToggleToolButton;
        make_menu_dropdown_button(copy_menu_button, _("Label as"));
        copy_folder_menu = new FolderMenu(copy_menu_button);

        Gtk.ToggleToolButton move_menu_button = set_toolbutton_action(builder,
            GearyController.ACTION_MOVE_MENU) as Gtk.ToggleToolButton;
        make_menu_dropdown_button(move_menu_button, _("Move to"));
        move_folder_menu = new FolderMenu(move_menu_button);

        // Assemble mark menu button.
        GearyApplication.instance.load_ui_file("toolbar_mark_menu.ui");
        Gtk.Menu mark_menu = GearyApplication.instance.ui_manager.get_widget("/ui/ToolbarMarkMenu")
            as Gtk.Menu;
        Gtk.ToggleToolButton mark_menu_button = set_toolbutton_action(builder,
            GearyController.ACTION_MARK_AS_MENU) as Gtk.ToggleToolButton;
        attach_menu(mark_menu, mark_menu_button);
        make_menu_dropdown_button(mark_menu_button, _("Mark"));

        // Setup the application menu.
        GearyApplication.instance.load_ui_file("toolbar_menu.ui");
        Gtk.Menu menu = GearyApplication.instance.ui_manager.get_widget("/ui/ToolbarMenu") as Gtk.Menu;
        attach_menu(menu, builder.get_object("menu_button") as Gtk.ToggleToolButton);

        toolbar.get_style_context().add_class("primary-toolbar");
        
        add(toolbar);
    }

    private void attach_menu(Gtk.Menu menu, Gtk.ToggleToolButton button) {
        menu.attach_to_widget(button, null);
        menu.deactivate.connect(() => {
            button.active = false;
        });
        button.clicked.connect(() => {
            // Prevent loops.
            if (!button.active) {
                return;
            }

            menu.popup(null, null, menu_popup_relative, 0, 0);
            menu.select_first(true);
        });
    }

    private Gtk.ToolButton set_toolbutton_action(Gtk.Builder builder, string action) {
        Gtk.ToolButton button = builder.get_object(action) as Gtk.ToolButton;
        button.set_related_action(GearyApplication.instance.actions.get_action(action));
        return button;
    }
}

