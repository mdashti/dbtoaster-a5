#ifndef DBTOASTER_STDADAPTORS_H
#define DBTOASTER_STDADAPTORS_H

#include <string>
#include <list>
#include <map>
#include <utility>

#include <boost/algorithm/string.hpp>
#include <boost/algorithm/string/find_iterator.hpp>
#include <boost/functional/hash.hpp>
#include <boost/shared_ptr.hpp>
#include <boost/tuple/tuple.hpp>

#include "runtime.hpp"

namespace dbtoaster {
  namespace runtime {

    using namespace std;

    struct csv_adaptor : public stream_adaptor
    {
      stream_id id;
      stream_event_type type;
      string schema;
      string delimiter;
      boost::hash<std::string> field_hash;

      csv_adaptor(stream_id i) : id(i) {}

      csv_adaptor(stream_id i, string sch) : id(i), schema(sch) {
        validate_schema();
      }

      csv_adaptor(stream_id i, int num_params,
                  const pair<string,string> params[]) : id(i)
      {
        for (int i = 0; i< num_params; ++i) {
          string k = params[i].first;
          string v = params[i].second;
          cout << "csv params: " << k << ": " << v << endl;
          if ( k == "fields" ) {
            delimiter = v;
          } else if ( k == "schema" ) {
            schema = parse_schema(v);
          } else if ( k == "eventtype" ) {
            type = v == "insert"? insert_tuple : delete_tuple;
          } else {
            cerr << "invalid csv adaptor parameter " << k << endl;
          }
        }
        validate_schema();
      }

      string parse_schema(string s) {
        string r = "";
        split_iterator<string::iterator> end;
        for (split_iterator<string::iterator> it =
             make_split_iterator(s, first_finder(",", is_equal()));
             it != end; ++it)
        {
          string ty = copy_range<std::string>(*it);
          if ( ty == "int" ) r += "i";
          else if ( ty == "float" ) r += "f";
          else if ( ty == "date" ) r += "d";
          else if ( ty == "hash" ) r += "h";
          else {
            cerr << "invalid csv schema type " << ty << endl;
            r = "";
          }
        }
        return r;
      }

      void validate_schema() {
        bool valid = true;
        string::iterator it = schema.begin();
        for (; valid && it != schema.end(); ++it) {
          switch(*it) {
            case 'e':  // event type
            case 'i':
            case 'f':
            case 'd':
            case 'h': break;
            default: valid = false; break;
          }
        }
        if ( !valid ) schema = "";
      }

      void process(const string& data, shared_ptr<list<stream_event> > dest)
      {
        if ( dest && schema != "" ) {
          // Interpret the schema.
          event_data tuple;
          string::iterator schema_it = schema.begin();
          bool valid = true;
          bool insert = true;

          split_iterator<string::const_iterator> field_end;
          for (split_iterator<string::const_iterator> field_it =
                  make_split_iterator(data, first_finder(delimiter, is_equal()));
               valid && schema_it != schema.end() && field_it != field_end;
               ++schema_it, ++field_it)
          {
            string field = copy_range<std::string>(*field_it);
            istringstream iss(field);
            bool ins; int i,y,m,d; double f;
            vector<string> date_fields;
            switch (*schema_it) {
              case 'e': iss >> ins; insert = ins; break;
              case 'i': iss >> i; tuple.push_back(i); break;
              case 'f': iss >> f; tuple.push_back(f); break;
              case 'h': tuple.push_back(static_cast<int>(field_hash(field))); break;
              case 'd':
                split(date_fields, field, is_any_of("-"));
                valid = false;
                if ( date_fields.size() == 3 ) {
                  y = atoi(date_fields[0].c_str());
                  m = atoi(date_fields[1].c_str());
                  d = atoi(date_fields[2].c_str());
                  if ( 0 < m && m < 13 && 0 < d && d <= 31) {
                    tuple.push_back(y*10000+m*100+d); valid = true;
                  }
                }
                break;
              default: valid = false; break;
            }
            valid = valid && !iss.fail();
          }

          if ( valid )  {
            stream_event e(insert? insert_tuple : delete_tuple, id, tuple);
            dest->push_back(e);
          } else {
            cout << "adaptor could not process " << data << endl;
          }
        }
      }
    };


    //////////////////////////////
    //
    // Order books

    namespace order_books
    {
      using namespace std;
      using namespace boost;
      using namespace dbtoaster::runtime;

      enum order_book_type { tbids, tasks, both };

      // Struct to represent messages coming off a socket/historical file
      struct order_book_message {
          double t;
          int id;
          string action;
          double volume;
          double price;
      };

      // Struct for internal storage, i.e. a message without the action or
      // order id.
      struct order_book_tuple {
          double t;
          int id;
          int broker_id;
          double volume;
          double price;
          order_book_tuple() {}

          order_book_tuple(const order_book_message& msg) {
            t = msg.t;
            id = msg.id;
            volume = msg.volume;
            price = msg.price;
          }

          order_book_tuple& operator=(order_book_tuple& other) {
            t = other.t;
            id = other.id;
            broker_id = other.broker_id;
            volume = other.volume;
            price = other.price;
            return *this;
          }

          void operator()(event_data& e) {
            if (e.size() > 0) e[0] = t; else e.push_back(t);
            if (e.size() > 1) e[1] = id; else e.push_back(id);
            if (e.size() > 2) e[2] = broker_id; else e.push_back(broker_id);
            if (e.size() > 3) e[3] = volume; else e.push_back(volume);
            if (e.size() > 4) e[4] = price; else e.push_back(price);
          }
      };

      typedef map<int, order_book_tuple> order_book;

      struct order_book_adaptor : public stream_adaptor {
        stream_id id;
        int num_brokers;
        order_book_type type;
        shared_ptr<order_book> bids;
        shared_ptr<order_book> asks;

        order_book_adaptor(stream_id sid, int nb, order_book_type t)
          : id(sid), num_brokers(nb), type(t)
        {
          bids = shared_ptr<order_book>(new order_book());
          asks = shared_ptr<order_book>(new order_book());
        }

        order_book_adaptor(stream_id sid, int num_params,
                           pair<string, string> params[])
        {
          id = sid;
          bids = shared_ptr<order_book>(new order_book());
          asks = shared_ptr<order_book>(new order_book());

          for (int i = 0; i < num_params; ++i) {
            string k = params[i].first;
            string v = params[i].second;
            cout << "order book adaptor params: "
                 << params[i].first << ", " << params[i].second << endl;

            if ( k == "book" ) {
              type = (v == "bids"? tbids : tasks);
            } else if ( k == "brokers" ) {
              num_brokers = atoi(v.c_str());
            } else if ( k == "validate" ) { // Ignore.
            } else {
              cerr << "Invalid order book param " << k << ", " << v << endl;
            }
          }
        }

        bool parse_error(const string& data, int field) {
          cerr << "Invalid field " << field << " message " << data << endl;
          return false;
        }

        // Expected message format: t, id, action, volume, price
        bool parse_message(const string& data, order_book_message& r) {
          string msg = data;
          char* start = &(msg[0]);
          char* end = start;
          char action;

          for (int i = 0; i < 5; ++i)
          {
              while ( *end && *end != ',' ) ++end;
              if ( start == end ) { return parse_error(data, i); }
              if ( *end == '\0' && i != 4 ) { return parse_error(data, i); }
              *end = '\0';

              switch (i) {
              case 0: r.t = atof(start); break;
              case 1: r.id = atoi(start); break;
              case 2:
                  action = *start;
                  if ( !(action == 'B' || action == 'S' ||
                         action == 'E' || action == 'F' ||
                         action == 'D' || action == 'X' ||
                         action == 'C' || action == 'T') )
                  {
                     return parse_error(data, i);
                  }

                  r.action = action;
                  break;

              case 3: r.volume = atof(start); break;
              case 4: r.price = atof(start); break;
              default: return parse_error(data, i);
              }

              start = ++end;
          }
          return true;
        }

        void process_message(const order_book_message& msg,
                             shared_ptr<list<stream_event> > dest)
        {
            bool valid = true;
            order_book_tuple r(msg);
            stream_event_type t = insert_tuple;

            if ( msg.action == "B" ) {
              if (type == tbids || type == both) {
                r.broker_id = ((int) rand()) % 9 + 1;
                (*bids)[msg.id] = r;
                t = insert_tuple;
              } else valid = false;
            }
            else if ( msg.action == "S" ) {
              if (type == tasks || type == both) {
                r.broker_id = ((int) rand()) % 9 + 1;
                (*asks)[msg.id] = r;
                t = insert_tuple;
              } else valid = false;
            }

            else if ( msg.action == "E" ) {
              order_book_tuple x;
              bool x_valid = true;
              order_book::iterator bid_it = bids->find(msg.id);
              if ( bid_it != bids->end() ) {
                x = r = bid_it->second;
                r.volume -= msg.volume;
                if ( r.volume <= 0.0 ) { bids->erase(bid_it); valid = false; }
                else { (*bids)[msg.id] = r; }
              } else {
                order_book::iterator ask_it = asks->find(msg.id);
                if ( ask_it != asks->end() ) {
                  x = r = ask_it->second;
                  r.volume -= msg.volume;
                  if ( r.volume <= 0.0 ) { asks->erase(ask_it); valid = false; }
                  else { (*asks)[msg.id] = r; }
                } else {
                  //cout << "unknown order id " << msg.id
                  //     << " (neither bid nor ask)" << endl;
                  valid = false;
                  x_valid = false;
                }
              }
              if ( x_valid ) {
                event_data fields(5);
                x(fields);
                stream_event y(delete_tuple, id, fields);
                dest->push_back(y);
              }
              t = insert_tuple;
            }

            else if ( msg.action == "F" )
            {
              order_book::iterator bid_it = bids->find(msg.id);
              if ( bid_it != bids->end() ) {
                r = bid_it->second;
                bids->erase(bid_it);
              } else {
                order_book::iterator ask_it = asks->find(msg.id);
                if ( ask_it != asks->end() ) {
                  r = ask_it->second;
                  asks->erase(ask_it);
                } else {
                  //cout << "unknown order id " << msg.id
                  //     << " (neither bid nor ask)" << endl;
                  valid = false;
                }
              }
              t = delete_tuple;
            }

            else if ( msg.action == "D" )
            {
              order_book::iterator bid_it = bids->find(msg.id);
              if ( bid_it != bids->end() ) {
                r = bid_it->second;
                bids->erase(bid_it);
              } else {
                order_book::iterator ask_it = asks->find(msg.id);
                if ( ask_it != asks->end() ) {
                  r = ask_it->second;
                  asks->erase(ask_it);
                } else {
                  //cout << "unknown order id " << msg.id
                  //     << " (neither bid nor ask)" << endl;
                  valid = false;
                }
              }
              t = delete_tuple;
            }

            /*
            // ignore for now...
            else if ( v->action == "X")
            else if ( v->action == "C")
            else if ( v->action == "T")
            */
            else { valid = false; }


            if ( valid ) {
              event_data fields(5);
              r(fields);
              stream_event e(t, id, fields);
              dest->push_back(e);
            }
        }

        void process(const string& data, shared_ptr<list<stream_event> > dest)
        {
            // Grab a message from the data.
            order_book_message r;
            bool valid = parse_message(data, r);

            if ( valid ) {
              // Process its action, updating the internal book.
              process_message(r, dest);
            }
        }
      };
    }

    //////////////////////////////
    //
    // TPCH files

    namespace tpch
    {
      struct tpch_adaptor : public csv_adaptor {
        int num_fields;

        tpch_adaptor(stream_id i, string tpch_rel) : csv_adaptor(i) {
          schema = parse_schema(get_schema(tpch_rel));
          if ( delimiter == "" ) delimiter = "|";
        }

        tpch_adaptor(stream_id i, string tpch_rel, int num_params,
                     const pair<string, string> params[])
          : csv_adaptor(i,num_params,params)
        {
          schema = parse_schema(get_schema(tpch_rel));
          if ( delimiter == "" ) delimiter = "|";
        }

        string get_schema(string tpch_rel) {
          string r = "";
          if ( tpch_rel == "lineitem" ) {
            r = "int,int,int,int,int,float,float,float,hash,hash,date,date,date,hash,hash,hash";
            num_fields = 16;
          } else if ( tpch_rel == "orders" ) {
            r = "int,int,hash,float,date,hash,hash,int,hash";
            num_fields = 9;
          } else if ( tpch_rel == "customer" ) {
            r = "int,hash,hash,int,hash,float,hash,hash";
            num_fields = 8;
          } else if ( tpch_rel == "supplier") {
            r = "int,hash,hash,int,hash,float,hash";
            num_fields = 7;
          } else if ( tpch_rel == "part") {
            r = "int,hash,hash,hash,hash,int,hash,float,hash";
            num_fields = 9;
          } else if ( tpch_rel == "partsupp") {
            r = "int,int,int,float,hash";
            num_fields = 5;
          } else if ( tpch_rel == "nation") {
            r = "int,hash,int,hash";
            num_fields = 4;
          } else if ( tpch_rel == "region") {
            r = "int,hash,hash";
            num_fields = 3;
          } else {
            cerr << "Invalid TPCH relation " << tpch_rel << endl;
          }
          return r;
        }
      };
    }
  }
}

#endif
