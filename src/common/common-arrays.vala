/* Copyright 2011 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

namespace Arrays {

public G[]? list_to_array<G>(Gee.List<G>? list) {
    if (list == null)
        return null;
    
    int length = list.size;
    
    G[] array = new G[length];
    for (int ctr = 0; ctr < length; ctr++)
        array[ctr] = list[ctr];
    
    return array;
}

public int int_find_low(int[] ar) {
    assert(ar.length > 0);
    
    int low = int.MAX;
    foreach (int i in ar) {
        if (i < low)
            low = i;
    }
    
    return low;
}

public void int_find_high_low(int[] ar, out int low, out int high) {
    assert(ar.length > 0);
    
    low = int.MAX;
    high = int.MIN;
    foreach (int i in ar) {
        if (i < low)
            low = i;
        
        if (i > high)
            high = i;
    }
}

}

