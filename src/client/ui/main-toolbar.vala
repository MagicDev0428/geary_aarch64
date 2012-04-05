/* Copyright 2011-2012 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

// Draws the main toolbar.
public class MainToolbar : Gtk.Box {
    private Gtk.Toolbar toolbar;
    private Gtk.Menu menu;
    private Gtk.Menu mark_menu;
    private Gtk.ToolButton menu_button;
    private Gtk.ToolButton mark_menu_button;
    
    public MainToolbar() {
        Object(orientation: Gtk.Orientation.VERTICAL, spacing: 0);
        
        GearyApplication.instance.load_ui_file("toolbar_mark_menu.ui");
        mark_menu = GearyApplication.instance.ui_manager.get_widget("/ui/ToolbarMarkMenu") as Gtk.Menu;
        
        GearyApplication.instance.load_ui_file("toolbar_menu.ui");
        menu = GearyApplication.instance.ui_manager.get_widget("/ui/ToolbarMenu") as Gtk.Menu;
        
        Gtk.Builder builder = GearyApplication.instance.create_builder("toolbar.glade");
        toolbar = builder.get_object("toolbar") as Gtk.Toolbar;
        
        Gtk.ToolButton new_message = builder.get_object(GearyController.ACTION_NEW_MESSAGE)
            as Gtk.ToolButton;
        new_message.set_related_action(GearyApplication.instance.actions.get_action(
            GearyController.ACTION_NEW_MESSAGE));
        
        Gtk.ToolButton reply_to_message = builder.get_object(GearyController.ACTION_REPLY_TO_MESSAGE)
            as Gtk.ToolButton;
        reply_to_message.set_related_action(GearyApplication.instance.actions.get_action(
            GearyController.ACTION_REPLY_TO_MESSAGE));
        
        Gtk.ToolButton reply_all_message = builder.get_object(GearyController.ACTION_REPLY_ALL_MESSAGE)
            as Gtk.ToolButton;
        reply_all_message.set_related_action(GearyApplication.instance.actions.get_action(
            GearyController.ACTION_REPLY_ALL_MESSAGE));
        
        Gtk.ToolButton forward_message = builder.get_object(GearyController.ACTION_FORWARD_MESSAGE)
            as Gtk.ToolButton;
        forward_message.set_related_action(GearyApplication.instance.actions.get_action(
            GearyController.ACTION_FORWARD_MESSAGE));
        
        Gtk.ToolButton archive_message = builder.get_object(GearyController.ACTION_DELETE_MESSAGE)
            as Gtk.ToolButton;
        archive_message.set_related_action(GearyApplication.instance.actions.get_action(
            GearyController.ACTION_DELETE_MESSAGE));
        
        mark_menu_button = builder.get_object(GearyController.ACTION_MARK_AS_MENU) as Gtk.ToolButton;
        mark_menu_button.set_related_action(GearyApplication.instance.actions.get_action(
            GearyController.ACTION_MARK_AS_MENU));
        mark_menu.attach_to_widget(mark_menu_button, null);
        mark_menu_button.clicked.connect(on_show_mark_menu);
        
        menu_button = builder.get_object("menu_button") as Gtk.ToolButton;
        menu.attach_to_widget(menu_button, null);
        menu_button.clicked.connect(on_show_menu);
        
        toolbar.get_style_context().add_class("primary-toolbar");
        
        add(toolbar);
    }
    
    private void on_show_menu() {
        menu.popup(null, null, menu_popup_relative, 0, 0);
    }
    
    private void on_show_mark_menu() {
        mark_menu.popup(null, null, menu_popup_relative, 0, 0);
    }
}
