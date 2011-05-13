/* Copyright 2011 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

public abstract class Geary.Imap.Parameter : Object, Serializable {
    public abstract async void serialize(Serializer ser) throws Error;
    
    // to_string() returns a representation of the Parameter suitable for logging and debugging,
    // but should not be relied upon for wire or persistent representation.
    public abstract string to_string();
}

public class Geary.Imap.NilParameter : Geary.Imap.Parameter {
    public const string VALUE = "NIL";
    
    private static NilParameter? _instance = null;
    
    public static NilParameter instance {
        get {
             if (_instance == null)
                _instance = new NilParameter();
            
            return _instance;
        }
    }
    
    private NilParameter() {
    }
    
    public static bool is_nil(string str) {
        return String.ascii_equali(VALUE, str);
    }
    
    public override async void serialize(Serializer ser) throws Error {
        ser.push_nil();
    }
    
    public override string to_string() {
        return VALUE;
    }
}

public class Geary.Imap.StringParameter : Geary.Imap.Parameter {
    public string value { get; private set; }
    public string? nullable_value {
        get {
            return String.is_empty(value) ? null : value;
        }
    }
    
    public StringParameter(string value) requires (!String.is_empty(value)) {
        this.value = value;
    }
    
    public bool equals_cs(string value) {
        return this.value == value;
    }
    
    public bool equals_ci(string value) {
        return this.value.down() == value.down();
    }
    
    // TODO: This does not check that the value is a properly-formed integer.  This should be
    // added later.
    public int as_int() throws ImapError {
        return int.parse(value);
    }
    
    // TODO: This does not check that the value is a properly-formed long.
    public long as_long() throws ImapError {
        return long.parse(value);
    }
    
    public override string to_string() {
        return value;
    }
    
    public override async void serialize(Serializer ser) throws Error {
        ser.push_string(value);
    }
}

public class Geary.Imap.LiteralParameter : Geary.Imap.Parameter {
    private MemoryInputStream mins = new MemoryInputStream();
    private long size = 0;
    
    public LiteralParameter(uint8[]? initial = null) {
        if (initial != null)
            add(initial);
    }
    
    public void add(uint8[] data) {
        if (data.length == 0)
            return;
        
        mins.add_data(data, null);
        size += data.length;
    }
    
    public long get_size() {
        return size;
    }
    
    public override string to_string() {
        return "{literal/%ldb}".printf(size);
    }
    
    public override async void serialize(Serializer ser) throws Error {
        ser.push_string("{%ld}".printf(size));
        ser.push_eol();
        yield ser.push_input_stream_literal_data_async(mins);
        
        // seek to start
        mins.seek(0, SeekType.SET);
    }
}

public class Geary.Imap.ListParameter : Geary.Imap.Parameter {
    private weak ListParameter? parent;
    private Gee.List<Parameter> list = new Gee.ArrayList<Parameter>();
    
    public ListParameter(ListParameter? parent, Parameter? initial = null) {
        this.parent = parent;
        
        if (initial != null)
            add(initial);
    }
    
    public ListParameter? get_parent() {
        return parent;
    }
    
    public void add(Parameter param) {
        bool added = list.add(param);
        assert(added);
    }
    
    public int get_count() {
        return list.size;
    }
    
    public new Parameter? get(int index) {
        return list.get(index);
    }
    
    public Parameter get_required(int index) throws ImapError {
        Parameter? param = list.get(index);
        if (param == null)
            throw new ImapError.TYPE_ERROR("No parameter at index %d", index);
        
        return param;
    }
    
    public Parameter get_as(int index, Type type) throws ImapError {
        assert(type.is_a(typeof(Parameter)));
        
        Parameter param = get_required(index);
        if (!param.get_type().is_a(type))
            throw new ImapError.TYPE_ERROR("Parameter %d is not of type %s", index, type.name());
        
        return param;
    }
    
    public Parameter? get_as_nullable(int index, Type type) throws ImapError {
        assert(type.is_a(typeof(Parameter)));
        
        Parameter param = get_required(index);
        if (param is NilParameter)
            return null;
        
        if (!param.get_type().is_a(type))
            throw new ImapError.TYPE_ERROR("Parameter %d is not of type %s", index, type.name());
        
        return param;
    }
    
    public StringParameter get_as_string(int index) throws ImapError {
        return (StringParameter) get_as(index, typeof(StringParameter));
    }
    
    public StringParameter? get_as_nullable_string(int index) throws ImapError {
        return (StringParameter?) get_as_nullable(index, typeof(StringParameter));
    }
    
    public ListParameter get_as_list(int index) throws ImapError {
        return (ListParameter) get_as(index, typeof(ListParameter));
    }
    
    public ListParameter? get_as_nullable_list(int index) throws ImapError {
        return (ListParameter?) get_as_nullable(index, typeof(ListParameter));
    }
    
    public LiteralParameter get_as_literal(int index) throws ImapError {
        return (LiteralParameter) get_as(index, typeof(LiteralParameter));
    }
    
    public LiteralParameter? get_as_nullable_literal(int index) throws ImapError {
        return (LiteralParameter?) get_as_nullable(index, typeof(LiteralParameter));
    }
    
    public Gee.List<Parameter> get_all() {
        return list.read_only_view;
    }
    
    // This replaces all existing parameters with those from the supplied list
    public void copy(ListParameter src) {
        list.clear();
        list.add_all(src.get_all());
    }
    
    protected string stringize_list() {
        StringBuilder builder = new StringBuilder();
        
        int length = list.size;
        for (int ctr = 0; ctr < length; ctr++) {
            builder.append(list[ctr].to_string());
            if (ctr < (length - 1))
                builder.append_c(' ');
        }
        
        return builder.str;
    }
    
    public override string to_string() {
        return "(%s)".printf(stringize_list());
    }
    
    protected void serialize_list(Serializer ser) throws Error {
        int length = list.size;
        for (int ctr = 0; ctr < length; ctr++) {
            list[ctr].serialize(ser);
            if (ctr < (length - 1))
                ser.push_space();
        }
    }
    
    public override async void serialize(Serializer ser) throws Error {
        ser.push_ascii('(');
        serialize_list(ser);
        ser.push_ascii(')');
    }
}

public class Geary.Imap.RootParameters : Geary.Imap.ListParameter {
    public RootParameters(Parameter? initial = null) {
        base (null, initial);
    }
    
    public RootParameters.clone(RootParameters root) {
        base (null);
        
        base.copy(root);
    }
    
    public override string to_string() {
        return stringize_list();
    }
    
    public override async void serialize(Serializer ser) throws Error {
        serialize_list(ser);
        ser.push_eol();
    }
}

