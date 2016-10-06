/*
 * Copyright 2016 Software Freedom Conservancy Inc.
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

public class ClientWebView : WebKit.WebView {


    private const double ZOOM_DEFAULT = 1.0;
    private const double ZOOM_FACTOR = 0.1;


    public bool is_loaded { get; private set; default = false; }

    private string _document_font;
    public string document_font {
        get {
            return _document_font;
        }
        set {
            _document_font = value;
            Pango.FontDescription font = Pango.FontDescription.from_string(value);
            WebKit.Settings settings = get_settings();
            settings.default_font_family = font.get_family();
            settings.default_font_size = font.get_size() / Pango.SCALE;
            set_settings(settings);
        }
    }

    private string _monospace_font;
    public string monospace_font {
        get {
            return _monospace_font;
        }
        set {
            _monospace_font = value;
            Pango.FontDescription font = Pango.FontDescription.from_string(value);
            WebKit.Settings settings = get_settings();
            settings.monospace_font_family = font.get_family();
            settings.default_monospace_font_size = font.get_size() / Pango.SCALE;
            set_settings(settings);
        }
    }

    // We need to wrap zoom_level (type float) because we cannot connect with float
    // with double (cf https://bugzilla.gnome.org/show_bug.cgi?id=771534)
    public double zoom_level_wrap {
        get { return zoom_level; }
        set { if (zoom_level != (float)value) zoom_level = (float)value; }
    }

    public string allow_prefix { get; private set; }

    private Gee.Map<string,File> cid_resources = new Gee.HashMap<string,File>();


    /** Emitted when a user clicks a link in this web view. */
    public signal void link_activated(string uri);


    public ClientWebView(WebKit.UserContentManager? content_manager = null) {
        WebKit.Settings setts = new WebKit.Settings();
        setts.enable_javascript = false;
        setts.enable_java = false;
        setts.enable_plugins = false;
        setts.enable_developer_extras = Args.inspector;
        setts.javascript_can_access_clipboard = true;

        Object(user_content_manager: content_manager, settings: setts);

        this.allow_prefix = random_string(10) + ":";

        this.resource_load_started.connect(on_resource_load_started);
        this.decide_policy.connect(on_decide_policy);
        this.load_changed.connect((web_view, event) => {
                if (event == WebKit.LoadEvent.FINISHED) {
                    this.is_loaded = true;
                }
            });

        GearyApplication.instance.config.bind(Configuration.CONVERSATION_VIEWER_ZOOM_KEY, this, "zoom_level_wrap");
        this.notify["zoom-level"].connect(() => { zoom_level_wrap = zoom_level; });
        this.scroll_event.connect(on_scroll_event);

        Settings system_settings = GearyApplication.instance.config.gnome_interface;
        system_settings.bind("document-font-name", this, "document-font", SettingsBindFlags.DEFAULT);
        system_settings.bind("monospace-font-name", this, "monospace-font", SettingsBindFlags.DEFAULT);
    }

    public void add_cid_resource(string cid, File file) {
        this.cid_resources[cid] = file;
    }

    /**
     * Selects all content in the web view.
     */
    public void select_all() {
        execute_editing_command(WebKit.EDITING_COMMAND_SELECT_ALL);
    }

    /**
     * Sends a copy command to the web view.
     */
    public void copy_clipboard() {
        execute_editing_command(WebKit.EDITING_COMMAND_CUT);
    }

    public bool can_copy_clipboard() {
        // can_execute_editing_command.begin(
        //     WebKit.EDITING_COMMAND_COPY,
        //     null,
        //     (obj, res) => {
        //         return can_execute_editing_command.end(res);
        //     });
        return false;
    }

    public void reset_zoom() {
        this.zoom_level == ZOOM_DEFAULT;
    }

    public void zoom_in() {
        this.zoom_level += (this.zoom_level * ZOOM_FACTOR);
    }

    public void zoom_out() {
        this.zoom_level -= (this.zoom_level * ZOOM_FACTOR);
    }

    private void on_resource_load_started(WebKit.WebView view,
                                          WebKit.WebResource resource,
                                          WebKit.URIRequest request) {
        const string ABOUT_BLANK = "about:blank";
        const string CID_PREFIX = "cid:";
        const string DATA_PREFIX = "data:";

        string? req_uri = request.get_uri();
        string resp_uri = ABOUT_BLANK;
        if (req_uri.has_prefix(CID_PREFIX)) {
            File? file = this.cid_resources[req_uri.substring(CID_PREFIX.length)];
            if (file != null) {
                resp_uri = file.get_uri();
            }
        } else if (req_uri.has_prefix(this.allow_prefix)) {
            resp_uri = req_uri.substring(this.allow_prefix.length);
        } else if (req_uri.has_prefix(DATA_PREFIX)) {
            resp_uri = req_uri;
        }
        request.set_uri(resp_uri);
    }

    private bool on_decide_policy(WebKit.WebView view,
                                  WebKit.PolicyDecision policy,
                                  WebKit.PolicyDecisionType type) {
        policy.ignore();
        if (type == WebKit.PolicyDecisionType.NAVIGATION_ACTION) {
            WebKit.NavigationPolicyDecision nav_policy =
                (WebKit.NavigationPolicyDecision) policy;
            if (nav_policy.navigation_action.is_user_gesture()) {
                link_activated(nav_policy.request.uri);
            }
        }
        return true;
    }

    private bool on_scroll_event(Gdk.EventScroll event) {
        if ((event.state & Gdk.ModifierType.CONTROL_MASK) != 0) {
            double dir = 0;
            if (event.direction == Gdk.ScrollDirection.UP)
                dir = -1;
            else if (event.direction == Gdk.ScrollDirection.DOWN)
                dir = 1;
            else if (event.direction == Gdk.ScrollDirection.SMOOTH)
                dir = event.delta_y;

            if (dir < 0) {
                zoom_in();
                return true;
            } else if (dir > 0) {
                zoom_out();
                return true;
            }
        }
        return false;
    }

}

