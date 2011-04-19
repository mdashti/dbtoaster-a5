
#ifndef DATA_TUPLE_ALGO_DEMO
#define DATA_TUPLE_ALGO_DEMO

#include <string>

/*
 * Tuple for storing order information.
 * stores time, local ID, broker id (currently it is algo ID), volume and price
 */

namespace DBToaster
{
    namespace DemoAlgEngine
    {
        using namespace std;

        struct DataTuple 
        {
            long long t;
            int id;
            int b_id;
            string action;
            int volume;
            int price;
            
            DataTuple & operator=(const DataTuple &rhs)
            {
                t=rhs.t;
                id=rhs.id;
                b_id=rhs.b_id;
                action=rhs.action;
                volume=rhs.volume;
                price=rhs.price;
                
                return *this;
            }
            
        };
    };
};
#endif       