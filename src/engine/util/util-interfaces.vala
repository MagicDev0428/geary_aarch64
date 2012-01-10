/* Copyright 2011-2012 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

public interface Geary.Comparable {
    public abstract int compare(Comparable other);
    
    public static int compare_func(void *a, void *b) {
        return ((Comparable *) a)->compare((Comparable *) b);
    }
}

public interface Geary.Equalable {
    public abstract bool equals(Equalable other);
    
    public static bool equal_func(void *a, void *b) {
        return ((Equalable *) a)->equals((Equalable *) b);
    }
}

public interface Geary.Hashable {
    public abstract uint to_hash();
    
    public static uint hash_func(void *ptr) {
        return ((Hashable *) ptr)->to_hash();
    }
    
    public static uint int64_hash(int64 value) {
        return hash_memory(&value, sizeof(int64));
    }
    
    /**
     * A rotating-XOR hash that can be used to hash memory buffers of any size.  Use only if
     * equality is determined by memory contents.
     */
    public static uint hash_memory(void *ptr, size_t bytes) {
        uint8 *u8 = (uint8 *) ptr;
        uint32 hash = 0;
        for (int ctr = 0; ctr < bytes; ctr++)
            hash = (hash << 4) ^ (hash >> 28) ^ (*u8++);
        
        return hash;
    }
}

