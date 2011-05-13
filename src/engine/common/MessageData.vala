/* Copyright 2011 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

/**
 * Common.MessageData is an abstract base class to unify the various message-related data and
 * metadata that may be associated with a mail message, whether it's embedded in its MIME
 * structure, its RFC822 header, IMAP metadata, or details from a POP server.
 */

public abstract class Geary.Common.MessageData {
    /**
     * to_string() is intended for debugging and logging purposes, not user-visible text or
     * serialization.
     */
    public abstract string to_string();
    
    /**
     * emit() is intended for sending the data on the wire in a textual format.
     */
    public abstract string emit();
}

public abstract class Geary.Common.StringMessageData : Geary.Common.MessageData {
    public string value { get; private set; }
    
    public StringMessageData(string value) {
        this.value = value;
    }
    
    public override string to_string() {
        return value;
    }
    
    public override string emit() {
        return value;
    }
}

public abstract class Geary.Common.IntMessageData : Geary.Common.MessageData {
    public int value { get; private set; }
    
    public IntMessageData(int value) {
        this.value = value;
    }
    
    public override string to_string() {
        return value.to_string();
    }
    
    public override string emit() {
        return value.to_string();
    }
}

public abstract class Geary.Common.LongMessageData : Geary.Common.MessageData {
    public long value { get; private set; }
    
    public LongMessageData(long value) {
        this.value = value;
    }
    
    public override string to_string() {
        return value.to_string();
    }
    
    public override string emit() {
        return value.to_string();
    }
}

