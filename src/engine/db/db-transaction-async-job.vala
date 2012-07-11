/* Copyright 2012 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

private class Geary.Db.TransactionAsyncJob : Object {
    private TransactionType type;
    private unowned TransactionMethod cb;
    private Cancellable cancellable;
    private NonblockingEvent completed;
    private TransactionOutcome outcome = TransactionOutcome.ROLLBACK;
    private Error? caught_err = null;
    
    protected TransactionAsyncJob(TransactionType type, TransactionMethod cb, Cancellable? cancellable) {
        this.type = type;
        this.cb = cb;
        this.cancellable = cancellable ?? new Cancellable();
        
        completed = new NonblockingEvent(cancellable);
    }
    
    public void cancel() {
        cancellable.cancel();
    }
    
    public bool is_cancelled() {
        return cancellable.is_cancelled();
    }
    
    // Called in background thread context
    internal void execute(Connection cx) {
        // execute transaction
        try {
            // possible was cancelled during interim of scheduling and execution
            if (is_cancelled())
                throw new IOError.CANCELLED("Async transaction cancelled");
            
            outcome = cx.exec_transaction(type, cb, cancellable);
        } catch (Error err) {
            debug("AsyncJob: transaction completed with error: %s", err.message);
            caught_err = err;
        }
        
        // notify foreground thread of completion
        // because Idle doesn't hold a ref, manually keep this object alive
        ref();
        
        // NonblockingSemaphore and its brethren are not thread-safe, so need to signal notification
        // of completion in the main thread
        Idle.add(on_notify_completed);
    }
    
    private bool on_notify_completed() {
        try {
            completed.notify();
        } catch (Error err) {
            if (caught_err != null) {
                debug("Unable to notify AsyncTransaction has completed w/ err %s: %s",
                    caught_err.message, err.message);
            } else {
                debug("Unable to notify AsyncTransaction has completed w/o err: %s", err.message);
            }
        }
        
        // manually unref; do NOT touch "this" once unref() returns, as this object may be freed
        unref();
        
        return false;
    }
    
    public async TransactionOutcome wait_for_completion_async(Cancellable? cancellable = null)
        throws Error {
        yield completed.wait_async(cancellable);
        if (caught_err != null)
            throw caught_err;
        
        return outcome;
    }
}

