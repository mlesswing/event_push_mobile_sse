
import 'package:eventsource/eventsource.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:http/http.dart' as http;
import 'package:keyboard_visibility/keyboard_visibility.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

//void main() => runApp(PushApp());
class CustomHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext context) {
    HttpClient client = super.createHttpClient(context);
    client.badCertificateCallback = (X509Certificate cert, String host, int port)=> true;
    return client;
  }
}

void main(){
  HttpOverrides.global = new CustomHttpOverrides();
  runApp(PushApp());
}

class PushApp extends StatelessWidget {

  final String title = 'MLS Push Mobile Client';
  final String _subscriberLogin = 'joe.schmoe';
  final String _subscriberPassword = 'nothing';
  final bool storeLongLifeKey = true;
  final String _lastChannelPrefs = "lastChannel";
  final String _lastMessagePrefs = "lastMessage";
  final String _userKeyPrefs = "userKey";
  final String _urlPrefs = "url";
  final int notConnected = 0;
  final int awaitingLogin = 1;
  final int loggedIn = 2;
  final int preferences = 3;
  final int channelGuide = 4;

  final int websocket = 0;
  final int sse = 1;
  final int longpoll = 2;

  //
  // ui_version = 0 original
  // us_version = 1 UI redesign 2019
  //
  final int ui_version = 1;

  SharedPreferences _prefs;

  Duration _mockPingInterval;
  int _mockPingFloor;

  String _channelURL;
  bool _activeChannel = false;
  String _currentChannel;
  String _lastChannel;
  String _subscriberId;
  LinkedHashMap _channelLineup = new LinkedHashMap();
  int _lastMessage = 0;
  int _lastActivity = 0;
  String _longLifeKey;
  bool _restartFlag = true;

  EventSource sseClient;
  List<ChannelItem> channelItems = List<ChannelItem>();
  _MessagePageState messageState;

  PushApp() : super() {
    //
    // Mock Ping
    //
    setPingInterval(15);

    //
    // perform async startup, allowing for reads from storage
    //
    _startup();
  }

  void setPingInterval(int seconds) {
    //
    // Mock Ping
    //
    // Floor - maximum inactivity time in milliseconds before checking server
    // Interval - how many seconds between activity checks
    //
    // The strategy is to check three times for activity before sending a ping
    // to the server to detect if a connection to be abandoned.
    //
    _mockPingFloor = seconds * 1000;
    _mockPingInterval = Duration(seconds: seconds ~/3);
  }

  /*
  Future<String> getChannelURL() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return await prefs.getString(_urlPrefs) ?? 'https://0.0.0.0:443';
  }
  */

  void _startup() async {
    //
    // perform the startup asynchronously to allow for access to storage
    //
    _prefs = await SharedPreferences.getInstance();

    //===========
    //_prefs.clear();
    //===========

    //
    // use long life key if we have one
    //
    if (storeLongLifeKey == false) {
      _clearUserKey();
    } else {
      _longLifeKey = await _prefs.getString(_userKeyPrefs);
    }

    //
    // bring back all cached messages
    //
    _clearLastMessage();

    //
    // bring back last channel
    //
    _lastChannel = await _prefs.getString(_lastChannelPrefs);

    //
    // bring back stored URL
    //

    if (_channelURL == null) {
      _channelURL = await _prefs.getString(_urlPrefs);
    }

    //print('startup');
    //print(_channelURL);

    //
    // if already configured, start connection
    //
    if (_channelURL == null) {
      _setChannelUrl('https://0.0.0.0:443');
    } else {
      _startConnection();
    }
  }

  void _onSseMessage(message) {
    if (message.data != null) {
      Map im = _decodeMessage(message.data);
      if (im['CLOSE'] != null) {
       _connectionClosed(im['CLOSE']);
      } else {
        _prepareDisplay(im);
      }
    } else {
      if (message.data == null) {
        //print('JEST A PING');
      }
    }
  }

  void _initialize (String aProvider, String aChannel, String aSubscriber, String anInterval) async {
    int check = num.tryParse(anInterval);
    if (check != null) {
      setPingInterval(check);
    }
     _subscriberId= aSubscriber;
    _currentChannel = aChannel;
    if (_currentChannel != _lastChannel) {
      _clearLastMessage();
      channelItems = List<ChannelItem>();
      messageState.setChannelItems(channelItems);
    }
    messageState.setConnectionState(loggedIn);
    messageState.setChannelName('Channel ' + _currentChannel);
    messageState.setProviderMessage('Connecting to Provider');
    messageState.setTitle(aProvider);
    messageState.rebuild();

    _onRESTMessage('subscriber_request=CHANNELS' + '&subscriber_id=' + _subscriberId);

    /*
    //-----
     */
    //_channelURL = await getChannelURL();
    //print('init SSE');
    //print(_channelURL);
    sseClient = await EventSource.connect(_channelURL + '/' + _subscriberId);
    sseClient.listen(_onSseMessage);

  }

  void _introduction(String aProvider, String aMessage) {
    if (_longLifeKey != null) {
      messageState.setChannelItems(channelItems);
      _onRESTMessage('subscriber_request=CONNECT&long_life_key=' + _longLifeKey);
    } else {
      messageState.setConnectionState(awaitingLogin);
      messageState.setProviderMessage(aMessage);
      messageState.setTitle(aProvider);
      messageState.rebuild();
    }
  }

  void _lineup(List<Object> channels) {
    _channelLineup = new LinkedHashMap();
    for (var i = 0; i < channels.length; i++) {
      Map<String, dynamic> aChannel = channels[i];
      print(aChannel);
      _channelLineup[aChannel['channel_number']] = {
        'description': aChannel['channel_description'],
        'detail': aChannel['channel_detail']
      };
    }
    messageState.setChannelDescription(_channelLineup[_currentChannel]['description']);
    messageState.rebuild();

    if (_currentChannel != _lastChannel) {
      _onRESTMessage('subscriber_request=SYNCHRONIZE&subscriber_id=' + _subscriberId);
    } else {
      if (_lastMessage != null) {
        _onRESTMessage('subscriber_request=SYNCHRONIZE&subscriber_id=' + _subscriberId + '&last_message=' + _lastMessage.toString());
      } else {
        _onRESTMessage('subscriber_request=SYNCHRONIZE&subscriber_id=' + _subscriberId);
      }
    }

    _lastChannel = _currentChannel;
    _prefs.setString(_lastChannelPrefs, _currentChannel);
  }

  void _loginConfirmation(String oneTimeKey, String longLifeKey) {
    messageState.setChannelItems(channelItems);
    if (oneTimeKey != null) {
      _onRESTMessage('subscriber_request=CONNECT&one_time_key=' + oneTimeKey);
    } else {
      _setUserKey(longLifeKey);
      _onRESTMessage('subscriber_request=CONNECT&long_life_key=' + longLifeKey);
    }
  }

  void _loginError() {
    channelItems = List<ChannelItem>();
    _clearPreferences();
    disconnect();
  }

  void _processMessage(Map im) {

    switch (im['response']) {
      case 'INITIALIZE':
        _initialize( im['provider_name'],
            im['channel_id'],
            im['subscriber_id'],
            im['ping_interval_seconds']);
        break;

      case 'INTRODUCTION':
        _introduction(im['provider_name'], im['introduction_message']);
        break;

      case 'LINEUP':
        _lineup(im['channels']);
        break;

      case 'LOGIN-CONFIRMATION':
        _loginConfirmation(im['one_time_key'],im['long_life_key']);
        break;

      case 'LOGIN-ERROR':
        _loginError();
        break;

      default:
        if (!_prepareDisplay(im)) {
          print('Unknown message response: '+ im['response']);
        }
    }
  }

  void _onRESTMessage(String aQuery) async {
    http.Response response;
    try {

      //print('onRERTMessage');
      //print(aQuery);
      //print(_channelURL);
      response = await http.get(_channelURL + '?' + aQuery);
      if (response.body != '') {
        //print('there');
        //print(response.body);
        Map im = _decodeMessage(response.body);
        //
        // Before a side channel (SSE or Long Poll) is open, a "close" is sent
        // through the REST channel.  This is used to detect expired keys and
        // simultaneous login.  A simultaneous login can be detected from
        // either mobile or web clients.
        //
        if (im['close'] != null) {
          int check = num.tryParse(im['close']);
          if (check != null) {
            _connectionClosed(check);
          }
        }
        _processMessage(im);
      }
    } catch (Exception) {
      //print(Exception);
    }
  }

  void _startConnection() async {
    _activeChannel = true;
    _restartFlag = true;
    _startActivityTimer();
    if (_longLifeKey == null) {
      _onRESTMessage('subscriber_request=INTRODUCE');
    } else {
      messageState.setChannelItems(channelItems);
      _onRESTMessage('subscriber_request=CONNECT&long_life_key=' + _longLifeKey);
    }

  }

  void _changeChannel(String aChannel) {
    if (aChannel != '') {
      _clearLastMessage();
      channelItems = List<ChannelItem>();
      messageState.setChannelItems(channelItems);
      _onRESTMessage('subscriber_request=CHANGE-CHANNEL&subscriber_id=' +
          _subscriberId + '&channel_number=' + aChannel);
    }
  }

  Future<Null> _channelDelay(int seconds) {
    return new Future.delayed(new Duration(milliseconds: seconds * 1000));
  }

  void _connectionClosed(int closeCode) async {
    _activeChannel = false;
    if (_restartFlag) {
      messageState.setConnectionState(notConnected);
      int delayValue = 10;
      switch (closeCode) {
        case 1005:
          messageState.setProviderMessage('Connection Closed');
          break;

        case 1008:
          channelItems = List<ChannelItem>();
          _clearPreferences();
          messageState.setProviderMessage('Expired Key');
          delayValue = 2;
          break;

        case 1013:
          messageState.setProviderMessage('Duplicate Login Detected');
          break;

        default:
          messageState.setProviderMessage('No Connection with the Service');
          delayValue = 20;
          break;
      }
      messageState.rebuild();
      await _channelDelay(delayValue);
      if (!_activeChannel) {
        _startConnection();
      }
    } else{
      messageState.setConnectionState(notConnected);
      messageState.rebuild();
    }
  }

  Map _decodeMessage(String aMessage) {
    _lastActivity = (new DateTime.now()).millisecondsSinceEpoch;
    return jsonDecode(aMessage);
  }

  void _startActivityTimer() {
    new Timer(_mockPingInterval, () async {
      if (_activeChannel) {
        //print('PING');
        int now = (new DateTime.now()).millisecondsSinceEpoch;
        if ((now - _lastActivity) > _mockPingFloor) {
          try {
            _lastActivity = now;
            final response = await http.get('https://' + getHost() + ':' + getPort() + '/mock_ping?subscriber_id=' + _subscriberId);
            if (response.statusCode == 200) {
              //print(response.body);
              if ( response.body == 'mock_pong') {
                _startActivityTimer();
              } else {
                disconnect();
              }
            } else {
              disconnect();
            }
          } catch (Exception) {
            //print('PING EXCEPTION');
            disconnect();
          }
        } else {
          _startActivityTimer();
        }
      }
    });
  }

  bool _prepareDisplay(im) {
    if (im['message_id'] != null) {
      _lastMessage = im['message_id'];
      _prefs.setInt(_lastMessagePrefs, _lastMessage);
    }
    switch (im['response']) {
      case 'MESSAGE':
        ChannelItem anItem = ChannelItem(
              im['response'],
              im['timestamp'],
              im['message_id'],
              im['text'],
              '',
            ui_version);
        _displayMessage(anItem);
        break;

      case 'OFF-MARKET':
        ChannelItem anItem = ChannelItem(
              im['response'],
              im['timestamp'],
              im['message_id'],
              im['event_context'],
              im['event_link'],
            ui_version);
        _displayMessage(anItem);
        break;

      case 'ON-MARKET':
        ChannelItem anItem = ChannelItem(
              im['response'],
              im['timestamp'],
              im['message_id'],
              im['event_context'],
              im['event_link'],
            ui_version);
        _displayMessage(anItem);
        break;

      case 'PRICE-DROP':
        ChannelItem anItem = ChannelItem(
              im['response'],
              im['timestamp'],
              im['message_id'],
              im['event_context'],
              im['event_link'],
            ui_version);
        _displayMessage(anItem);
        break;

      default:
          //
          // upon opening the channel, the server sends a 'subscriber' object
          // {subscriber: XXXXXXXXX}
          //print(im);
        return false;
    }
    return true;
  }

  void _displayMessage(ChannelItem anItem){
    channelItems.insert(0, anItem);
    messageState.setChannelItems(channelItems);
    messageState.rebuild();
  }

  //
  // preferences
  //
  void _clearPreferences() {
    _prefs.clear();
    _clearUserKey();
    _clearLastMessage();
  }

  void _clearUserKey() {
    _longLifeKey = null;
    _prefs.setString(_userKeyPrefs, null);
  }

  void _setUserKey(String value) {
    _longLifeKey = value;
    _prefs.setString(_userKeyPrefs, value);
  }

  void _setChannelUrl(String value) {
    _channelURL = value;
    _prefs.setString(_urlPrefs, value);
  }

  void _clearLastMessage() {
    _lastMessage = null;
    _prefs.setInt(_lastMessagePrefs, null);
  }

  //
  // public methods
  //

  void changeAppLifecycle(AppLifecycleState state) {
    print('STATE CHANGE: ' + state.toString());
    if (state.index == 0) {
      if (!_activeChannel) {
        _startConnection();
      }
    }
  }

  void suspend() {
    _restartFlag = false;
  }

  void disconnect() {
    if (_subscriberId != null) {
      _connectionClosed(1005);
      _onRESTMessage('subscriber_request=SIDE-CHANNEL-CLOSE&subscriber_id=' + _subscriberId);
    }
  }

  void downChannel() {
    var nextChannel = '';
    var found = false;
    for (var key in _channelLineup.keys) {
      if (key == _currentChannel) {
        found = true;
        break;
      }
      if (found == false) {
        nextChannel = key;
      }
    }
    _changeChannel(nextChannel);
  }

  void login(String aName, String aPassword) {
    aName = _subscriberLogin;
    aPassword = _subscriberPassword;
    if (storeLongLifeKey == true) {
      _onRESTMessage('subscriber_request=MOBILE-LOGIN&subscriber_login=' + aName + '&subscriber_password=' + aPassword);
    } else {
      _onRESTMessage('subscriber_request=LOGIN&subscriber_login=' + aName + '&subscriber_password=' + aPassword);
    }
  }

  void registerMessageState(_MessagePageState aStatefulWidget) {
    messageState = aStatefulWidget;
  }

  void setURL(String host, int port) {
    messageState.setConnectionState(notConnected);
    messageState.rebuild();
    String aURL = "https://" + host + ":" + port.toString();
    if (aURL != _channelURL) {
      _setChannelUrl(aURL);
    }
    if (_activeChannel) {
      disconnect();
    }
    _startConnection();
  }

  String getHost() {
    return Uri.parse(_channelURL).host;
  }

  String getPort() {
    return Uri.parse(_channelURL).port.toString();
  }

  String getScheme() {
    return Uri.parse(_channelURL).scheme;
  }

  int getUiVersion() {
    return ui_version;
  }

  String getCurrentChannel() {
    return _currentChannel;
  }

  void selectChannel(String aChannel) {
    print(_currentChannel);
    if (aChannel != '') {
      _clearLastMessage();
      channelItems = List<ChannelItem>();
      messageState.setChannelItems(channelItems);
      _onRESTMessage('subscriber_request=CHANGE-CHANNEL&subscriber_id=' +
          _subscriberId + '&channel_number=' + aChannel);
    }
  }

  void showGuide() {
    messageState.setConnectionState(channelGuide);
    messageState.rebuild();
  }

  LinkedHashMap getChannelLineup() {
    return _channelLineup;
  }

  void upChannel() {
    var nextChannel = '';
    var found = false;
    for (var key in _channelLineup.keys) {
      if (found == true) {
        nextChannel = key;
        break;
      }
      if (key == _currentChannel) {
        found = true;
      }
    }
    _changeChannel(nextChannel);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: MessagePage(
        title: this.title,
        channelItems: this.channelItems,
        parent: this,
        connectionState: this.notConnected,
      ),
    );
  }
}

class MessagePage extends StatefulWidget {

  String channelDescription = 'No Channel';
  List<ChannelItem> channelItems;
  String channelName = 'No Channel';
  String title;
  String providerMessage = 'Provider not Connected';
  int connectionState;
  int pushStyle;

  final PushApp parent;

  MessagePage({
    Key key,
    @required this.title,
    @required this.channelItems,
    @required this.parent,
    @required this.connectionState,
  }) : super(key: key);

  @override
  _MessagePageState createState() => _MessagePageState(parent);
  /*
  _MessagePageState createState() {
    _MessagePageState aState = _MessagePageState(parent);
    //aState.registerMessageState(parent);
    return aState;
  }
  */

}

class _MessagePageState extends State<MessagePage> with WidgetsBindingObserver {
//class _MessagePageState extends State<MessagePage> {

  final TextEditingController _hostFilter = new TextEditingController();
  final TextEditingController _nameFilter = new TextEditingController();
  final TextEditingController _passwordFilter = new TextEditingController();
  final TextEditingController _portFilter = new TextEditingController();

  String _host = "";
  String _name = "";
  String _password = "";
  int _port = 433;
  int _ui_version = 0;

  _MessagePageState(PushApp aParent) {

    _hostFilter.addListener(_hostListen);
    _nameFilter.addListener(_nameListen);
    _passwordFilter.addListener(_passwordListen);
    _portFilter.addListener(_portListen);

    KeyboardVisibilityNotification().addNewListener(
      onChange: (bool visible) {
        if (widget.connectionState == 1) {
          if (!visible) {
            widget.parent.login(_name, _password);
          }
        }
        if (widget.connectionState == 3) {
          if (!visible) {
            widget.parent.setURL(_host, _port);
          }
        }
      },
    );
    aParent.registerMessageState(this);
    _ui_version = aParent.getUiVersion();
  }

  /*
  _MessagePageState() {

    _hostFilter.addListener(_hostListen);
    _nameFilter.addListener(_nameListen);
    _passwordFilter.addListener(_passwordListen);
    _portFilter.addListener(_portListen);

    KeyboardVisibilityNotification().addNewListener(
      onChange: (bool visible) {
        if (widget.connectionState == 1) {
          if (!visible) {
            widget.parent.login(_name, _password);
          }
        }
        if (widget.connectionState == 3) {
          if (!visible) {
            widget.parent.setURL(_host, _port);
          }
        }
      },
    );

  }
  */

  void rebuild() {
    setState(() {});
  }

  void _hostListen() {
    if (_hostFilter.text.isEmpty) {
      _host = "";
    } else {
      _host = _hostFilter.text;
    }
  }

  void _nameListen() {
    if (_nameFilter.text.isEmpty) {
      _name = "";
    } else {
      _name = _nameFilter.text;
    }
  }

  void _passwordListen() {
    if (_passwordFilter.text.isEmpty) {
      _password = "";
    } else {
      _password = _passwordFilter.text;
    }
  }

  void _portListen() {
    if (_portFilter.text.isEmpty) {
      _port = 443;
    } else {
      int check = num.tryParse(_portFilter.text);
      if (check != null) {
        _port = check;
      }
    }
  }

  void registerMessageState(PushApp aParent) {
    aParent.registerMessageState(this);
  }

  void setConnectionState(int aState) {
    widget.connectionState = aState;
  }

  void setChannelDescription(String aDescription) {
    widget.channelDescription = aDescription;
  }

  void setChannelName(String aName) {
    widget.channelName = aName;
  }

  void setProviderMessage(String aMessage) {
    widget.providerMessage = aMessage;
  }

  void setChannelItems(List<ChannelItem> aList) {
    widget.channelItems = aList;
  }

  void setTitle(String aTitle) {
    widget.title = aTitle;
  }

  void _launchURL(aUrl) async {
    if (await canLaunch(aUrl)) {
      await launch(aUrl);
    } else {
      throw 'Could not launch $aUrl';
    }
  }

  Widget _bulletLine(String bulletText) {
    return new Padding(
      padding: const EdgeInsets.only(left: 64.0, top: 6.0),
      child: new Row(
          children: <Widget> [
            new Container(
              height: 4.0,
              width: 4.0,
              decoration: new BoxDecoration(
                color: Colors.black,
                shape: BoxShape.circle,
              ),
            ),
            new SizedBox(width: 10.0,),
            new Text(
              bulletText,
              style: new TextStyle(fontSize: 14.00,),
              textAlign: TextAlign.left,
            ),
          ]
      ),
    );
  }

  /*
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    print('init');
  }

  @override
  void dispose() {
    print('dispose');
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
  */

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.parent.changeAppLifecycle(state);
    //print(state.toString());
    /*
    setState(() {
      _lastLifecycleState = state;
    });
    */
  }

  @override
  Widget build(BuildContext context) {

    switch (widget.connectionState) {

    // ERROR Screen
      case 0:
        return Scaffold(
          appBar: AppBar(
            centerTitle: true,
            backgroundColor: Colors.deepPurple,
            actions: <Widget>[
              IconButton(icon: const Icon(Icons.more_vert),
                tooltip: 'Retry',
                onPressed: () {
                widget.parent.suspend();
                setConnectionState(3);
                this.rebuild();
                },
              ),
            ],
            title: Text(widget.title,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.white,
                fontSize: 20.0,
              ),
            ),
            bottom: PreferredSize(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0.0, 0.0, 0.0, 12.0),
                child: Text(
                  widget.providerMessage,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16.0,
                  ),
                ),
              ),
              preferredSize: Size(0.0, 20.0),
            ),
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(top: 60.0),
                child: Text(
                  'Looking for a Connection',
                  style: TextStyle(
                    fontSize: 18.00,
                    fontWeight: FontWeight.bold,
                    color: Colors.deepPurpleAccent,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 36.0, top: 18.0, bottom: 12.0),
                child: Text(
                  'Some of the reasons for this could be:',
                  style: TextStyle(fontSize: 14.00,),
                  textAlign: TextAlign.left,
                ),
              ),
              _bulletLine('Poor cellular or WiFi connection'),
              _bulletLine('Login detected from another device'),
              _bulletLine('Service is temporarily down'),
              _bulletLine('Initial configuration not complete'),
              Padding(
                padding: const EdgeInsets.only(left: 36.0, top: 18.0),
                child: Text(
                  'A connection will be made when possible.',
                  style: TextStyle(fontSize: 14.00,),
                  textAlign: TextAlign.left,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 20.0),
                child: Text(
                  'Please be Patient',
                  style: TextStyle(
                    fontSize: 18.00,
                    fontWeight: FontWeight.bold,
                    color: Colors.deepPurpleAccent,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              Padding(
                  padding: const EdgeInsets.only(left: 36.0, top: 50.0, right: 36.0),
                  child: RichText(
                    text: TextSpan(
                      text: 'First time note: ',
                      style: TextStyle(
                        fontSize: 14.00,
                        fontWeight: FontWeight.bold,
                        color: Colors.black,
                      ),
                      children: <TextSpan> [
                        TextSpan(
                          text: 'Configure the service using the icon in the upper right hand corner.',
                          style: TextStyle(
                            fontSize: 14.00,
                            fontWeight: FontWeight.normal,
                            color: Colors.black,
                          ),
                        ),
                      ],
                    ),
                  )
              ),
            ],
          ),
        );
        break;

    // LOGIN screen
      case 1:
        {
          return Scaffold(
            appBar: AppBar(
              centerTitle: true,
              backgroundColor: Colors.deepPurple,
              title: Text(widget.title,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  fontSize: 20.0,
                ),
              ),
              bottom: PreferredSize(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0.0, 0.0, 0.0, 12.0),
                  child: Text(
                    widget.providerMessage,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16.0,
                    ),
                  ),
                ),
                preferredSize: Size(0.0, 20.0),
              ),
            ),
            body: Container(
              padding: EdgeInsets.only(top: 20.0, left: 24.0, right: 24.0),
              child: Column(
                children: <Widget>[
                  Column(
                    children: <Widget> [
                      TextField(
                        controller: _nameFilter,
                        decoration: InputDecoration(
                          labelText: 'Name',
                          labelStyle: TextStyle(
                            color: Colors.deepPurple,
                            fontSize: 20.0,
                          ),
                        ),
                      ),
                      TextField(
                        controller: _passwordFilter,
                        decoration: InputDecoration(
                          labelText: 'Password',
                          labelStyle: TextStyle(
                            color: Colors.deepPurple,
                            fontSize: 20.0,
                          ),
                        ),
                        obscureText: true,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }
        break;

    // MESSAGES Screen
      case 2:
        List aList = List<Widget>();
        for (var i = 0; i < widget.channelItems.length; i++) {
          if (_ui_version == 0) {
            aList.add(
                Container (
                  decoration: BoxDecoration (
                    color: widget.channelItems[i].asBackroundColor(),
                  ),
                  child: ListTile(
                    leading: IconButton(
                      padding: const EdgeInsets.all(0.0),
                      tooltip: 'Details',
                      //iconSize: 20,
                      icon: Icon(
                        widget.channelItems[i].asIcon(),
                        color: widget.channelItems[i].asIconColor(),
                      ),
                      onPressed: () {
                        _launchURL(widget.channelItems[i].asLink());
                      },
                    ),
                    subtitle: Row(
                      children: <Widget>[
                        Text(widget.channelItems[i].asHint(),
                        ),
                        Text(widget.channelItems[i].asMessageId(),
                        ),
                      ],
                    ),
                    title: Text(widget.channelItems[i].asString(),
                    ),
                    contentPadding: const EdgeInsets.all(0.0),
                    //isThreeLine: false,
                    dense: true,
                    //trailing: Text(f.format(new DateTime.now())),
                  )
                ));
            }

            if (_ui_version == 1) {
              aList.add(Container(
                padding: EdgeInsets.symmetric(vertical: 12.0, horizontal: 0.0),
                margin: EdgeInsets.symmetric(vertical: 0.0),
                decoration: BoxDecoration(
                  color: widget.channelItems[i].asBackroundColor(),
                  borderRadius: BorderRadius.circular(6.0),
                  border: Border.all(color: Colors.purple[50]),
                ),
                child: Column(
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        IconButton(
                          tooltip: 'Details',
                          iconSize: 30,
                          icon: Icon(
                            widget.channelItems[i].asIcon(),
                            color: widget.channelItems[i].asIconColor(),),
                            onPressed: () =>
                            {
                              _launchURL(widget.channelItems[i].asLink())
                            },
                          ),
                        Expanded(
                          child: Container(
                            margin: EdgeInsets.symmetric(horizontal: 6.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  widget.channelItems[i].asString(),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 15.0,
                                  ),
                                ),
                                Text(
                                  '',
                                  style: TextStyle(
                                    fontSize: 6.0,
                                  ),
                                ),
                                Row(
                                  children: <Widget>[
                                    Text(
                                      widget.channelItems[i].asHint(),
                                      style: TextStyle(
                                        color: widget.channelItems[i]
                                            .asIconColor(),
                                        fontSize: 16.0,
                                      ),
                                    ),
                                    Text(
                                      widget.channelItems[i].asMessageId(),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ));
          }

        }

        return Scaffold(
          appBar: AppBar(
            centerTitle: true,
            backgroundColor: Colors.deepPurple,
            leading: IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh',
                onPressed: widget.parent.disconnect,
            ),
            title: Text(widget.title,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.white,
                fontSize: 20.0,
              ),
            ),

            actions: <Widget>[
                IconButton(
                  icon: const Icon(Icons.more_vert),
                    tooltip: 'Channel Guide',
                    onPressed: widget.parent.showGuide,
                ),
            ],

            bottom:
            PreferredSize(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0.0, 0.0, 0.0, 0.0),
                child: SwipeDetector(
                  child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: <Widget>[
                        IconButton(
                            tooltip: 'Down',
                            icon: const Icon(Icons.keyboard_arrow_left),
                            color: Colors.white,
                            onPressed: widget.parent.downChannel
                        ),
                        Material(
                            type: MaterialType.transparency,
                            textStyle: TextStyle(
                              color: Colors.white,
                              fontSize: 16.0,),
                            child: InkWell(
                                onTap: () {},
                                child: Text(
                                  widget.channelName + ' - ' + widget.channelDescription,
                                  //style: TextStyle(color: Colors.white,
                                  //fontSize: 16.0,),
                                )
                            )
                        ),
                        IconButton(
                            tooltip: 'Up',
                            icon: const Icon(Icons.keyboard_arrow_right),
                            color: Colors.white,
                            onPressed: widget.parent.upChannel
                        ),
                      ]
                  ),
                  onSwipeLeft: widget.parent.downChannel,
                  onSwipeRight: widget.parent.upChannel,
                  swipeConfiguration: SwipeConfiguration(
//                      horizontalSwipeMaxHeightThreshold: 50.0,
                    horizontalSwipeMinDisplacement:40.0,
                    horizontalSwipeMinVelocity: 200.0,
                  ),
                ),
              ),
              preferredSize: Size(0.0, 20.0),
            ),
          ),
          body:
          SwipeDetector(
            child:
            CustomScrollView(
              shrinkWrap: true,
              slivers: <Widget>[
                SliverPadding(
                  padding: const EdgeInsets.all(0.0),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate(
                      aList,
                    ),
                  ),
                ),
              ],
            ),
            onSwipeLeft: widget.parent.downChannel,
            onSwipeRight: widget.parent.upChannel,
            swipeConfiguration: SwipeConfiguration(
//              horizontalSwipeMaxHeightThreshold: 50.0,
              horizontalSwipeMinDisplacement:40.0,
              horizontalSwipeMinVelocity: 200.0,
            ),
          ),
        );
        break;

    // PREFERENCES Screen
      case 3:
        _host = widget.parent.getHost();
        _hostFilter.text = _host;
        _portFilter.text = widget.parent.getPort();
        return Scaffold(
          appBar: AppBar(
            centerTitle: true,
            backgroundColor: Colors.deepPurple,
            title: Text('Connection Information',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.white,
                fontSize: 20.0,
              ),
            ),
            bottom: PreferredSize(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0.0, 0.0, 0.0, 12.0),
                child: Text(
                  "Ask Your Provider For These",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16.0,
                  ),
                ),
              ),
              preferredSize: Size(0.0, 20.0),
            ),
          ),
          body: Padding(
            padding: EdgeInsets.only(top: 20.0, left: 24.0, right: 24.0),
            child: Column(
              children: <Widget>[

                TextField(
                  controller: _hostFilter,
                  decoration: InputDecoration(
                    labelText: 'Host',
                    labelStyle: TextStyle(
                      color: Colors.deepPurple,
                      fontSize: 22.0,
                    ),
                  ),
                ),
                TextField(
                  controller: _portFilter,
                  decoration: InputDecoration(
                    labelText: 'Port',
                    labelStyle: TextStyle(
                      color: Colors.deepPurple,
                      fontSize: 22.0,
                    ),
                  ),
                  keyboardType: TextInputType.number,
                ),

              ],
            ),
          ),
        );
        break;

    // CHANNEL GUIDE Screen
      case 4:

        LinkedHashMap _lineup = widget.parent.getChannelLineup();
        String currentChannel = widget.parent.getCurrentChannel();
        List aList = List<Widget>();
        _lineup.forEach((aChannel, value) {
          Color backgroundColor;
          if (aChannel == currentChannel) {
            backgroundColor = Colors.amber[50];
          } else {
            backgroundColor = Colors.white;
          }

          aList.add(
              Container(
                padding:
                EdgeInsets.symmetric(
                    vertical: 12.0,
                    horizontal: 0.0),
                margin: EdgeInsets.symmetric(vertical: 0.0),
                decoration:
                BoxDecoration(
                  color: backgroundColor,
                  borderRadius: BorderRadius.circular(6.0),
                  border: Border.all(color: Colors.purple[50]),
                ),
                child:InkWell(
                  onTap: () =>
                  {
                    widget.parent.selectChannel(aChannel)
                  },
                  child: Column(
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Padding(
                              padding: EdgeInsets.only(left: 12.0, right:6.0),
                              child:
                              Text(aChannel,
                                style: TextStyle(
                                  color: Colors.deepPurple[400],
                                  fontWeight: FontWeight.bold,
                                  fontSize: 28.0,
                                ),),
                            ),
                            Expanded(
                                child:
                                Container(
                                  margin: EdgeInsets.symmetric(horizontal: 12.0),
                                  child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: <Widget>[
                                        Text(
                                          value['description'],
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 20.0,
                                          ),
                                        ),
                                        Text(
                                          '',
                                          style: TextStyle(
                                            fontSize: 6.0,
                                          ),
                                        ),
                                        Text(
                                          value['detail'],
                                          overflow: TextOverflow.ellipsis,
                                          maxLines: 3,
                                          style: TextStyle(
                                            fontSize: 16.0,
                                          ),
                                        ),
                                      ]
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ]
                  ),
                ),
              )
          );

        });

        return Scaffold(
          appBar: AppBar(
            centerTitle: true,
            backgroundColor: Colors.deepPurple,
            title: Text('Channel Guide',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.white,
                fontSize: 20.0,
              ),
            ),
            bottom: PreferredSize(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0.0, 0.0, 0.0, 12.0),
                child: Text(
                  "Your current channel is highlighted",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16.0,
                  ),
                ),
              ),
              preferredSize: Size(0.0, 20.0),
            ),
          ),
          body: Padding(
            padding: EdgeInsets.only(top: 20.0, left: 10.0, right: 10.0),
            child:
            CustomScrollView(
              shrinkWrap: true,
              slivers: <Widget>[
                SliverPadding(
                  padding: const EdgeInsets.all(0.0),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate(
                      aList,
                    ),
                  ),
                ),
              ],
            ),

          ),
        );
        break;

      default:
        //print('Unknown connection state ');
        return null;
        break;
    }

  }
}

//
// ChannelItem contains data to display
//
class ChannelItem {
  IconData _anIcon;
  String _hint;
  String _eventLink;
  String _description;
  Color _anIconColor;
  Color _backgroundColor;
  String _messageId;

  //
  // ui_version = 0 original
  // ui_version = 1 UI redesign 2019
  //
  ChannelItem(String msgType, String timestamp, int anId, String rawInput, String aLink, int ui_version) {
    if (anId != 0) {
      _messageId = anId.toString() + ' sent at ' + timestamp;
    } else {
      _messageId = 'sent at ' + timestamp;
    }
    _eventLink = aLink;
    _description = rawInput;
    _backgroundColor = Colors.white;
    switch (msgType) {
      case 'MESSAGE':
        {
          _anIcon = Icons.message;
          if (ui_version == 0) {
            _anIconColor = Colors.orange;
          }
          if (ui_version == 1) {
            _anIconColor = Colors.purple[800];
          }
          _backgroundColor = Colors.amber[50];
          _hint = 'message ';
        }
        break;

      case 'OFF-MARKET':
        {
          _anIcon = Icons.block;
          if (ui_version == 0) {
            _anIconColor = Colors.blue;
            _hint = 'message ';
          }
          if (ui_version == 1) {
            _anIconColor = Colors.red;
            _hint = 'closed ';
          }
        }
        break;

      case 'ON-MARKET':
        {
          _anIcon = Icons.add;
          if (ui_version == 0) {
            _anIconColor = Colors.green;
            _hint = 'message ';
          }
          if (ui_version == 1) {
            _anIconColor = Colors.green[700];
            _hint = 'new ';
          }
        }
        break;

      case 'PRICE-DROP':
        {
          _anIcon = Icons.change_history;
          if (ui_version == 0) {
            _anIconColor = Colors.orange;
            _hint = 'message ';
          }
          if (ui_version == 1) {
            _anIconColor = Colors.blue[700];
            _hint = 'change ';
          }
        }
        break;

      default:
        {
          //print('Unknown response ' + msgType);
        }
        break;
    }
  }

  IconData asIcon() {
    return _anIcon;
  }

  Color asIconColor() {
    return _anIconColor;
  }

  Color asBackroundColor() {
    return _backgroundColor;
  }

  String asHint() {
    return _hint;
  }

  String asLink() {
    return _eventLink;
  }

  String asMessageId() {
    return _messageId;
  }

  String asString() {
    return _description;
  }
}

class SwipeConfiguration {

  double horizontalSwipeMaxHeightThreshold = 50.0;
  double horizontalSwipeMinDisplacement = 100.0;
  double horizontalSwipeMinVelocity = 300.0;

  SwipeConfiguration({
    double horizontalSwipeMaxHeightThreshold,
    double horizontalSwipeMinDisplacement,
    double horizontalSwipeMinVelocity,
  }) {

    if (horizontalSwipeMaxHeightThreshold != null) {
      this.horizontalSwipeMaxHeightThreshold = horizontalSwipeMaxHeightThreshold;
    }

    if (horizontalSwipeMinDisplacement != null) {
      this.horizontalSwipeMinDisplacement = horizontalSwipeMinDisplacement;
    }

    if (horizontalSwipeMinVelocity != null) {
      this.horizontalSwipeMinVelocity = horizontalSwipeMinVelocity;
    }
  }
}

class SwipeDetector extends StatelessWidget {
  final Widget child;

  final Function() onSwipeLeft;
  final Function() onSwipeRight;
  final SwipeConfiguration swipeConfiguration;

  SwipeDetector(
      {@required this.child,
        this.onSwipeLeft,
        this.onSwipeRight,
        SwipeConfiguration swipeConfiguration})
      : this.swipeConfiguration = swipeConfiguration == null
      ? SwipeConfiguration()
      : swipeConfiguration;

  @override
  Widget build(BuildContext context) {

    DragStartDetails startHorizontalDragDetails;
    DragUpdateDetails updateHorizontalDragDetails;

    return GestureDetector(
      child: child,
      onHorizontalDragStart: (dragDetails) {
        startHorizontalDragDetails = dragDetails;
      },
      onHorizontalDragUpdate: (dragDetails) {
        updateHorizontalDragDetails = dragDetails;
      },
      onHorizontalDragEnd: (endDetails) {
        double dx = updateHorizontalDragDetails.globalPosition.dx -
            startHorizontalDragDetails.globalPosition.dx;
        double dy = updateHorizontalDragDetails.globalPosition.dy -
            startHorizontalDragDetails.globalPosition.dy;
        double velocity = endDetails.primaryVelocity;

        if (dx < 0) dx = -dx;
        if (dy < 0) dy = -dy;
        double positiveVelocity = velocity < 0 ? -velocity : velocity;

        //print("$dx $dy $velocity $positiveVelocity");

        if (dx < swipeConfiguration.horizontalSwipeMinDisplacement) return;
        if (dy > swipeConfiguration.horizontalSwipeMaxHeightThreshold) return;
        if (positiveVelocity < swipeConfiguration.horizontalSwipeMinVelocity)
          return;

        if (velocity < 0) {
          //Swipe Up
          if (onSwipeLeft != null) {
            onSwipeLeft();
          }
        } else {
          //Swipe Down
          if (onSwipeRight != null) {
            onSwipeRight();
          }
        }
      },
    );
  }
}

