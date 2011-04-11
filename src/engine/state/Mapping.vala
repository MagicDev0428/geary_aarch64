/* Copyright 2011 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

public delegate uint Geary.State.Transition(uint state, uint event, void *user);

public class Geary.State.Mapping {
    public uint state;
    public uint event;
    public Transition transition;
    
    public Mapping(uint state, uint event, Transition transition) {
        this.state = state;
        this.event = event;
        this.transition = transition;
    }
}

namespace Geary.State {

// A utility Transition for nop transitions (i.e. it merely returns the state passed in).
public uint nop(uint state, uint event, void *user) {
    return state;
}

}
