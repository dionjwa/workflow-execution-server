/* Set up the metaframe channel */
console.log("Initializing workflow metaframe");
var superagent = require('superagent');
global.metaframe = new Metaframe({debug:true});

metaframe.ready.then(function() {
  metaframe.log('Workflow execution engine metaframe connection ready');
  metaframe.sendDimensions({width:700,height:500});
}, function(err) {
  metaframe.error('Workflow execution engine metaframe connection err=' + JSON.stringify(err));
});

global.QueryString = function () {
  // This function is anonymous, is executed immediately and 
  // the return value is assigned to QueryString!
  var query_string = {};
  var query = window.location.search.substring(1);
  var vars = query.split("&");
  for (var i=0;i<vars.length;i++) {
    var pair = vars[i].split("=");
        // If first entry with this name
    if (typeof query_string[pair[0]] === "undefined") {
      query_string[pair[0]] = decodeURIComponent(pair[1]);
        // If second entry with this name
    } else if (typeof query_string[pair[0]] === "string") {
      var arr = [ query_string[pair[0]],decodeURIComponent(pair[1]) ];
      query_string[pair[0]] = arr;
        // If third or later entry with this name
    } else {
      query_string[pair[0]].push(decodeURIComponent(pair[1]));
    }
  }
  return query_string;
}();

metaframe.log('QueryString' + JSON.stringify(QueryString));

var inputs = {}
//Get the workflow url. We'll download the content of that url
metaframe.onRemoteMethodCall(function(rpcDefinition) {

  if (rpcDefinition.method != "InputPipeUpdate") {
    return;
  }

  metaframe.log("metaframe.onRemoteMethodCall that wants to execute a workflow " + JSON.stringify(rpcDefinition).substr(0, 200));

  var params = rpcDefinition.params;
  var pipeId = params != null ? params.id : null;
  var pipeValue = params != null ? params.value : null;

  metaframe.log(pipeId + "=" + (pipeValue != null ? pipeValue.substr(0, 20) : null));

  inputs[pipeId] = pipeValue;

  if (pipeValue == null) {
    document.getElementById("status").innerHTML = "Status: not running, null inputs";
    metaframe.log(pipeId + '=null, not doing any workflow execution');
    return;
  }



  // var formData = new FormData();
  // formData.append(pipeId, pipeValue);

  // //Try running the workflow
  // var formData = inputs;
  var url = 'http://localhost:4000/workflow/run?';
  var first = true;
  for (var key in QueryString) {
    if (QueryString.hasOwnProperty(key)) {
      if (!first) {
        url = url + '&';
      } else {
        first = false;
      }
      url = url + key + '=' + QueryString[key];
    }
  }
  // var url = 'http://localhost:4000/workflow/run?git=' + QueryString.git + '&cwl=' + QueryString.cwl;
  metaframe.log('url' + url);

  var req = superagent.post(url);

  for (var pipeId in inputs) {
    if (inputs.hasOwnProperty(pipeId)) {
      req.field(pipeId, inputs[pipeId])
    }
  }
  inputs[pipeId] = pipeValue;

  document.getElementById("status").innerHTML = "Status: running";

  req.end(function(err, response) {
    if (err != null) {
      document.getElementById("status").innerHTML = "Status: ran but error: " + err;
      console.error(err);
      return;
    }

    document.getElementById("status").innerHTML = "Status: success ";
    // console.log('body=' + body);
    if (response.statusCode == 200) {
      console.log('Success');
      console.log("body" + response.body);
      console.log("response" + response);
      for (var pipeId in response.body) {
        var localPipeId = pipeId;
        if (response.body.hasOwnProperty(pipeId)) {
          var cwloutBlob = response.body[pipeId];
          // var dataLocation = 'http://dev.cwl-workflow-execution:4000/' + cwloutBlob.location;
          var dataLocation = 'http://localhost:4000/' + cwloutBlob.location;
          metaframe.setOutputPipeValue(localPipeId, dataLocation);
          // axios.get(dataLocation)
          //   .then(function (response) {
          //     var pdbData = response.data;
          //     console.log("setting output pipe=" + localPipeId + " data=" + pdbData);
          //     metaframe.setOutputPipeValue(localPipeId, pdbData);
          //   })
          //   .catch(function (error) {
          //     console.error(error);
          //   });
        }
      }
    } else {
      metaframe.error('non-200 response body=' + response.body);
    }
  });

  // request.post({url:url, formData: formData},
  //   function(err, httpResponse, body) {
  //     if (err != null) {
  //       console.error(err);
  //       return;
  //     }
  //     console.log('httpResponse.statusCode=', httpResponse.statusCode);
  //     console.log('body=' + body);
  //     if (httpResponse.statusCode == 200) {
  //     } else {
  //       console.error('non-200 response body=' + body);
  //     }
  //   });
});


