/**
 * Autogenerated by Thrift
 *
 * DO NOT EDIT UNLESS YOU ARE SURE THAT YOU KNOW WHAT YOU ARE DOING
 */
package DBToaster.Viewer.query19;


import java.util.Set;
import java.util.HashSet;
import java.util.Collections;
import org.apache.thrift.IntRangeSet;
import java.util.Map;
import java.util.HashMap;

public class DmlType {
  public static final int insertTuple = 0;
  public static final int deleteTuple = 1;

  public static final IntRangeSet VALID_VALUES = new IntRangeSet(
    insertTuple, 
    deleteTuple );

  public static final Map<Integer, String> VALUES_TO_NAMES = new HashMap<Integer, String>() {{
    put(insertTuple, "insertTuple");
    put(deleteTuple, "deleteTuple");
  }};
}