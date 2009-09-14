
#ifndef ORDER_MANAGER_DEMO
#define ORDER_MANAGER_DEMO

#include <iostream>
#include <string>
#include <deque>

#include <boost/ptr_container/ptr_map.hpp>
#include <boost/bind.hpp>
#include <boost/asio.hpp>
#include <boost/thread.hpp>

#include <tr1/tuple>

#include "WriterConnection.h"
#include "DataTuple.h"
#include "AlgoTypeDefs.h"

/*
 * Creates an interface for wrting and reciving data from Exchange Simulator
 */

namespace DBToaster
{
    namespace DemoAlgEngine
    {
        using namespace std;
        using namespace tr1;
        using namespace boost;
        using namespace DBToaster::DemoAlgEngine;

        class OrderManager
        {
        public:

            //Constructor initates io_services number of shares and total amount of money available
            OrderManager(boost::asio::io_service& io_service, int shares, int m):
                localIOService(io_service), 
                numberShares(shares),
                currentMoney(m)
            {
                //initiates current local id for keeping track of the order numbers and 
                localIdCounter=0;
                //current stock price
                currentStockPrice=0;
                //creates a writer for sending orders to the server
                writer=new WriterConnection(localIOService, 0);

            }
            
            // Request for a set of orders, all orders are executed asyncronously. 
            void sendOrders(boost::function<void ()>  handler, deque<AlgoMessages*> & messages)
            {
                
                deque<AlgoMessages*>::iterator message=messages.begin();
                
                //queues up all order requests form algorithms
                for (; message != messages.end(); message++)
                {
                    sendOrder((*message)->tuple, (*message)->type);
                }
                
                
                localIOService.post(handler);
               
            }
            
            //handles each order 
            int sendOrder(DataTuple & tuple, int & type)
            {
                //this function is called by algorithms
                //if type is 0 no return is expected (on delete)
                //type 1 returns internal id. 


                if (type == 1)
                {
                    //this is desiged for "S" and "B" orders;
                    localIdCounter++;
                    writer->write((boost::bind(&OrderManager::handleOrder, this, _1, localIdCounter)), tuple, type);

                    return localIdCounter;
                }
                else
                {
                    //for deletes 
                    writer->write(boost::bind(&OrderManager::handleOrder, this, tuple, localIdCounter), tuple, type);
                    return tuple.id;
                }

            }

            // in responce for a write it takes a responding tuple from server
            //and stores it. Thus saving a tuple order ID for future. 
            void handleOrder(DataTuple & tuple, int & id)
            {
                boost::mutex::scoped_lock lock(mutex);
                
                ptr_map<LocalID, DataTuple>::iterator item=dataOrders.find(id);

                if (item == dataOrders.end())
                {
                    dataOrders[id]=tuple;
                    orderIDtoLocalId[tuple.id]=id;
                }
                else
                {
                    cout<<"The item with OrderID "<<tuple.id<<" and LocalID "
                        <<id<<" is already in the database"<<endl;
                }
            }

            //creates a continuous reading loop to get data from a server
            void startReading(boost::asio::io_service& io_service)
            {
                reader=new WriterConnection(io_service, 1);

                reader->read(boost::bind(&OrderManager::processOrder,this, _1, 0));
            }

            //takes a tuple from the server and extracts useful information from it
            void processOrder(DataTuple & tuple, int & temp)
            {
                ptr_map<OrderID, LocalID>::iterator item=orderIDtoLocalId.find(tuple.id);
                
                //check for current price
                if (tuple.action == "E" || tuple.action == "F" || tuple.action == "U")
                {
                    if (tuple.price !=0) {
                        currentStockPrice=tuple.price;
                    }
                }

                //if order Id referes to a local tuple
                if (item != orderIDtoLocalId.end())
                {//tuple was generated by one of the algorithms;
                    processTuple(tuple, *(item->second));
                }     
                //continuous reading         
                reader->read(boost::bind(&OrderManager::processOrder, this, _1, 0));
            }
            
            // extracts a latest current price
            double getCurrentStockPrice()
            {
                return (double)currentStockPrice;
            }
        
            //extracts a tuple referenced by the local ID
            DataTuplesPair  getTuple(LocalID localID)
            {
                DataTuplesPair t(dataOrders[localID], executedOrders[localID]);
                return t;
            }

            //gets current number of shares
            int getCurrentShares()
            {
                return numberShares;
            }

            //gets current amount of money 
            int getCurrentMoney()
            {
                return currentMoney;
            }

        private:

            //if a tuple references a local tuple
            //takes appropriate action and updates statistics
            void processTuple(DataTuple & tuple, LocalID & id)
            {
                boost::mutex::scoped_lock lock(mutex);
                
                if (DEBUG){
                    cout<<"In processTuple: ";
                    cout<<tuple.t<<" "<<tuple.id<<" "<<tuple.b_id<<" "<<tuple.action<<" "<<tuple.volume<<" "<<tuple.price<<endl;
                }
                
                if (tuple.action == "D")
                {
                    dataOrders.erase(id);
                }

                if (tuple.action == "E")
                {
                    if (dataOrders[id].action == "S")
                    {
                        currentMoney+=tuple.volume*tuple.price;
                        numberShares-=tuple.volume;
                    }
                    else if (dataOrders[id].action == "B")
                    {
                        currentMoney-=tuple.volume*tuple.price;
                        numberShares+=tuple.volume;
                    }
                    else
                    {
                        cout<<"order with ID "<<id<<" and action ("<< dataOrders[id].action<<") "<<endl;
                        cout<<"In OrderManager: dataOrders should only store S/B orders (fn:processingTuple)"<<endl;
                    }

                    dataOrders[id].volume=dataOrders[id].volume-tuple.volume;

                    ptr_map<LocalID, DataTuple>::iterator item=executedOrders.find(id);
                    if (item != executedOrders.end())
                    {
                        (item->second)->volume+=tuple.volume;
                        //TODO: account for the price somehow ...
                    }
                    else
                    {
                        executedOrders[id]=tuple;
                    }
                }

                if (tuple.action == "F")
                {
                    if (dataOrders[id].action == "S")
                    {
                        currentMoney+=tuple.volume*tuple.price;
                        numberShares-=tuple.volume;
                    }
                    else if (dataOrders[id].action == "B")
                    {
                        currentMoney-=tuple.volume*tuple.price;
                        numberShares+=tuple.volume;
                    }
                    else
                    {
                        cout<<"In OrderManager: dataOrders should only store S/B orders (fn:processingTuple)"<<endl;
                    }

                    ptr_map<LocalID, DataTuple>::iterator item=executedOrders.find(id);
                    if (item != executedOrders.end())
                    {
                        (item->second)->volume+=tuple.volume;
                        (item->second)->action="F";
                        //TODO: account for the price somehow ...
                    }
                    else
                    {
                        executedOrders[id]=tuple;
                    }

                    dataOrders.erase(id);
                }
            }

            boost::asio::io_service& localIOService;

            boost::mutex mutex;
            bool DEBUG;

            WriterConnection *             writer;
            WriterConnection *             reader;

            int localIdCounter;

            int numberShares;
            int currentMoney;
            
            int currentStockPrice;

            ptr_map<LocalID, DataTuple>   dataOrders;
            ptr_map<OrderID, LocalID>     orderIDtoLocalId;
            ptr_map<LocalID, DataTuple>   executedOrders;

        };
    };
};


#endif
