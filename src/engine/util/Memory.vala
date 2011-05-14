/* Copyright 2011 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

public abstract class Geary.Memory.AbstractBuffer {
    public abstract size_t get_size();
    
    public abstract size_t get_actual_size();
    
    public abstract uint8[] get_buffer();
    
    /**
     * Returns an InputStream that can read the buffer in its current entirety.  Note that the
     * InputStream may share its memory buffer(s) with the AbstractBuffer but does not hold 
     * references to them or the AbstractBuffer itself.  Thus, the AbstractBuffer should only be 
     * destroyed after all InputStreams are destroyed or exhausted.
     */
    public abstract InputStream get_input_stream();
}

public class Geary.Memory.Buffer : Geary.Memory.AbstractBuffer {
    private uint8[] buffer;
    private size_t filled;
    
    public Buffer(uint8[] buffer, size_t filled) {
        this.buffer = buffer;
        this.filled = filled;
    }
    
    public override size_t get_size() {
        return filled;
    }
    
    public override size_t get_actual_size() {
        return buffer.length;
    }
    
    public override uint8[] get_buffer() {
        return buffer[0:filled];
    }
    
    public override InputStream get_input_stream() {
        return new MemoryInputStream.from_data(buffer[0:filled], null);
    }
}

public class Geary.Memory.GrowableBuffer : Geary.Memory.AbstractBuffer {
    private class BufferFragment {
        public uint8[] buffer;
        public size_t reserved_bytes = 0;
        public unowned uint8[]? active = null;
        
        public BufferFragment(size_t bytes) {
            buffer = new uint8[bytes];
        }
        
        public unowned uint8[]? reserve(size_t requested_bytes) {
            if((reserved_bytes + requested_bytes) > buffer.length)
                return null;
            
            active = buffer[reserved_bytes:reserved_bytes + requested_bytes];
            reserved_bytes += requested_bytes;
            
            return active;
        }
        
        public void adjust(uint8[] active, size_t adjusted_bytes) {
            assert(this.active == active);
            
            assert(active.length >= adjusted_bytes);
            size_t freed = active.length - adjusted_bytes;
            
            assert(reserved_bytes >= freed);
            reserved_bytes -= freed;
            
            active = null;
        }
    }
    
    private size_t min_fragment_bytes;
    private Gee.ArrayList<BufferFragment> fragments = new Gee.ArrayList<BufferFragment>();
    
    public GrowableBuffer(size_t min_fragment_bytes = 1024) {
        this.min_fragment_bytes = min_fragment_bytes;
    }
    
    public unowned uint8[] allocate(size_t bytes) {
        if (fragments.size > 0) {
            unowned uint8[]? buffer = fragments[fragments.size - 1].reserve(bytes);
            if (buffer != null)
                return buffer;
        }
        
        BufferFragment next = new BufferFragment(
            (bytes < min_fragment_bytes) ? min_fragment_bytes : bytes);
        fragments.add(next);
        
        unowned uint8[]? buffer = next.reserve(bytes);
        assert(buffer != null);
        
        return buffer;
    }
    
    public void adjust(uint8[] buffer, size_t adjusted_bytes) {
        assert(fragments.size > 0);
        
        fragments[fragments.size - 1].adjust(buffer, adjusted_bytes);
    }
    
    public override size_t get_size() {
        size_t size = 0;
        foreach (BufferFragment fragment in fragments)
            size += fragment.reserved_bytes;
        
        return size;
    }
    
    public override size_t get_actual_size() {
        size_t size = 0;
        foreach (BufferFragment fragment in fragments)
            size += fragment.buffer.length;
        
        return size;
    }
    
    public override uint8[] get_buffer() {
        uint8[] buffer = new uint8[get_size()];
        uint8 *buffer_ptr = (uint8 *) buffer;
        foreach (BufferFragment fragment in fragments) {
            GLib.Memory.copy(buffer_ptr, fragment.buffer, fragment.reserved_bytes);
            buffer_ptr += fragment.reserved_bytes;
        }
        
        return buffer;
    }
    
    public override InputStream get_input_stream() {
        // TODO: add_data() copies the buffer, hence the optimization doesn't work yet.
        MemoryInputStream mins = new MemoryInputStream();
        foreach (BufferFragment fragment in fragments)
            mins.add_data(fragment.buffer[0:fragment.reserved_bytes], null);
        
        return mins;
    }
}

