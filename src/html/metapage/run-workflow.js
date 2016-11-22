/* Set up the metaframe channel */
console.log("Initializing workflow metaframe");
// console.log('window', window);
var superagent = require('superagent');
// var request = window.returnExports;
// console.log('window.returnExports', window.returnExports);
var metaframe = Metaframe.getChannel();

metaframe.ready.then(function() {
  console.log('Workflow execution engine metaframe connection ready');
}, function(err) {
  console.error('Workflow execution engine metaframe connection',err);
});


var QueryString = function () {
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

console.log('QueryString', QueryString);

var inputs = {}
//Get the workflow url. We'll download the content of that url
metaframe.registerRpc("InputPipeUpdate", function(params) {
  if (params.parentId != metaframe.parentId) {
    return;
  }
  var pipeId = params != null ? params.id : null;
  var pipeValue = params != null ? params.value : null;

  console.log(pipeId + "=" + (pipeValue != null ? pipeValue.substr(0, 20) : null));

  inputs[pipeId] = pipeValue;

  if (pipeValue == null) {
    console.log(pipeId + '=null, not doing any workflow execution');
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
  console.log('url', url);

  var req = superagent.post(url);

  for (var pipeId in inputs) {
    if (inputs.hasOwnProperty(pipeId)) {
      req.field(pipeId, inputs[pipeId])
    }
  }
  inputs[pipeId] = pipeValue;

  req.end(function(err, response) {
    if (err != null) {
      console.error(err);
      return;
    }

    // console.log('body=' + body);
    if (response.statusCode == 200) {
      console.log('Success');
      console.log("body", response.body);
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
      console.error('non-200 response body=' + response.body);
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


axios.get('https://files.rcsb.org/download/1c7d.pdb')
  .then(function (response) {
    var pdbData = response.data;
    metaframe.setInputPipeValue('uploadpdb.pdb', pdbData);
  })
  .catch(function (error) {
    console.error(error);
  });