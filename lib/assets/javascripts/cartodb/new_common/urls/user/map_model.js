var cdb = require('cartodb.js');

/**
 * Represents a User's map URL.
 * TODO: The new maps are not yet implemented so right now these paths point to the current /viz/ paths.
 */
module.exports = cdb.core.Model.extend({

  toEdit: function() {
    return this._toStr('map');
  },

  toPublic: function() {
    return this._toStr('public_map');
  },

  _toStr: function() {
    var userUrl = this.get('userUrl');
    return userUrl._toStr.call(userUrl, 'viz', this.get('vis').get('id'), Array.prototype.slice.call(arguments, 0));
  }
});
