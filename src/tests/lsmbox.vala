/* Copyright 2011 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution. 
 */

MainLoop? main_loop = null;
Geary.Imap.ClientSession? sess = null;
string? user = null;
string? pass = null;
string? mailbox = null;
int start = 0;
int count = 0;

async void async_start() {
    try {
        yield sess.connect_async();
        yield sess.login_async(user, pass);
        
        Geary.Folder folder = yield sess.select_async(mailbox);
        
        Geary.MessageStream? mstream = folder.read(start, count);
        
        bool ok = false;
        if (mstream != null) {
            Gee.List<Geary.Message>? msgs = yield mstream.read();
            if (msgs != null && msgs.size > 0) {
                foreach (Geary.Message msg in msgs)
                    stdout.printf("%s\n", msg.to_string());
                
                ok = true;
            }
        }
        
        if (!ok)
            debug("Unable to examine mailbox %s", mailbox);
        
        yield sess.close_mailbox_async();
        
        yield sess.logout_async();
        yield sess.disconnect_async();
    } catch (Error err) {
        debug("Error: %s", err.message);
    }
    
    main_loop.quit();
}

int main(string[] args) {
    if (args.length < 6) {
        stderr.printf("usage: lsmbox <user> <pass> <mailbox> <start #> <count>\n");
        
        return 1;
    }
    
    main_loop = new MainLoop();
    
    user = args[1];
    pass = args[2];
    mailbox = args[3];
    start = int.parse(args[4]);
    count = int.parse(args[5]);
    
    sess = new Geary.Imap.ClientSession("imap.gmail.com", 993);
    async_start.begin();
    
    main_loop.run();
    
    return 0;
}

