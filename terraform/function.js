// CloudFront Function (cloudfront-js-2.0, viewer-request):
// 1. 301 www.<domain> → apex, preserving path + query.
// 2. Clean URLs against the private S3/OAC origin: "/" → "/index.html",
//    extensionless paths → append ".html" (this site uses flat .html files).
async function handler(event) {
  var request = event.request;
  var host = request.headers.host && request.headers.host.value;

  if (host && host.startsWith('www.')) {
    var apex = host.slice(4);
    var qs = '';
    var keys = Object.keys(request.querystring);
    if (keys.length > 0) {
      qs = '?' + keys.map(function (k) {
        return request.querystring[k].value === '' ? k : k + '=' + request.querystring[k].value;
      }).join('&');
    }
    return {
      statusCode: 301,
      statusDescription: 'Moved Permanently',
      headers: { location: { value: 'https://' + apex + request.uri + qs } },
    };
  }

  var uri = request.uri;
  if (uri.endsWith('/')) {
    request.uri = uri + 'index.html';
  } else if (!uri.includes('.')) {
    request.uri = uri + '.html';
  }
  return request;
}
