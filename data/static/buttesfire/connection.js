Buttesfire.Connection = Class.create({
  initialize: function () {
    this.len = 0;
    this.aborting = false;
    this.req = null;
    this.seperator = "--xbuttesfirex\n";
  
  },
  
  closeConnection: function () {
    this.aborting = true;
    if (this.req && this.req.transport)
      this.req.transport.abort();
    this.aborting = false;
  },
  
  connect: function () {
    this.closeConnection();
    this.len = 0;
    var connection = this;
    this.req = new Ajax.Request('/stream', {
      method: 'get',
      onException: function (req, e) {
        console.log(e);
        if (! connection.aborting)
          setTimeout(connection.connect.bind(connection), 2000);
      },
      onInteractive: connection.handleUpdate.bind(connection),
      onComplete: function () {
        if (! connection.aborting)
          setTimeout(connection.connect.bind(connection), 2000);
      }
    });
  },
  
  handleUpdate: function (transport) {
    var time = new Date();
    var data = transport.responseText.slice(this.len);
    var start, end;
    start = data.indexOf(this.seperator);
    if (start > -1) {
      start += this.seperator.length;
      end = data.indexOf(this.seperator, start);
      if (end == -1) return;
    }
    else return;
    this.len += (end + this.seperator.length) - start;
    data = data.slice(start, end);
  
    try {
      data = data.evalJSON();
    }
    catch (err) {
      console.log(err);
      return;
    }
    
    buttesfire.handleActions(data.actions);
    buttesfire.displayMessages(data.msgs);
  
    // reconnect if lag is over 5 seconds... not a good way to do this.
    var lag = time / 1000 -  data.time;
    if (lag > 5) {
      console.log("lag is " + Math.round(lag) + "s, reconnecting...");
      this.connect();
    }
  },
  
  requestTab: function (name, session, callback) {
    var connection;
    new Ajax.Request('/say', {
      method: 'get',
      parameters: {session: session, msg: "/window new " + name},
      onSuccess: function (trans) {
        connection.handleUpdate(trans);
        callback();
      }
    });
  },
  
  partChannel: function (channel) {
    new Ajax.Request('/say', {
      method: 'get',
      parameters: {chan: channel.name, session: channel.session, msg: "/part"},
    });
  },
  
  sayMessage: function (event) {
    var form = event.element();
    new Ajax.Request('/say', {
      method: 'get',
      parameters: form.serialize(),
    });
    form.childNodes[3].value = '';
    Event.stop(event);
  },
});