package org.dbtoaster.cumulus.config;

import java.util.Properties;
import java.util.HashMap;
import java.util.Map;
import java.util.HashSet;
import java.util.ArrayList;
import java.io.FileInputStream;
import java.io.IOException;
import org.jruby.CompatVersion;
import org.jruby.embed.PathType;
import org.jruby.embed.ScriptingContainer;
import org.apache.log4j.PropertyConfigurator;

public class CumulusConfig extends Properties
{
  HashMap<String,String> parameters;
  HashSet<CumulusOption> parameterOptions;
  
  public interface RubyConfigIface {
    public void load(String input);
    public void parse_opt(String opt, String arg);
  }
  
  public CumulusConfig()
  {
    super();
    parameters = new HashMap<String,String>();
    parameterOptions = new HashSet<CumulusOption>();
    
    defineOption("n", "node", true);
  }
  
  public CumulusConfig(String args[]) throws IOException
  {
    this();
    configure(args);
  }
  
  public void defineOption(String longName, boolean requiresParameter)
  {
    defineOption(null, longName, requiresParameter);
  }
  
  public void defineOption(String shortName, String longName, boolean requiresParameter)
  {
    parameterOptions.add(new CumulusOption(longName, shortName, requiresParameter));
    if(!requiresParameter){
      parameters.put(longName, null);
    }
  }
  
  public void assertProperty(String property)
  {
    if(getProperty(property) == null)
    {
      System.err.println("Config file does not contain property : " + property);
    }
  }
  
  public void dumpProperty(String property)
  {
    System.out.println(property + " = " + getProperty(property));
  }
  
  public void setSystemProperty(String property)
  {
    assertProperty(property);
    System.setProperty(property, getProperty(property));
  }
  
  public void usage()
  {
    System.err.println("Usage: {script} cumulusConfigFile [options]");
    System.exit(1);
  }
  
  public void configure(String args[]) throws IOException
  {
    ArrayList<String> nonParameterArgs = new ArrayList<String>();
    CumulusOption option = null;
    for(String arg : args){
      if(option == null){
        if(isOption(arg)){
          boolean found = false;
          for(CumulusOption potential : parameterOptions){
            if(potential.match(arg)){
              found = true;
              if(potential.requiresParameter){
                option = potential;
              } else {
                parameters.put(potential.name, "YES");
                setProperty(potential.name, "YES");
              }
              break;
            }
          }
          if(!found){
            System.err.println("Invalid parameter switch : " + arg);
            usage();
          }
        } else {
          nonParameterArgs.add(arg);
        }
      } else {
        parameters.put(option.name, arg);
        setProperty(option.name, arg);
        option = null;
      }
    }
    args = nonParameterArgs.toArray(args);
  
    if(args.length < 2){ usage(); }
    load(new FileInputStream(args[0]));
    setProperty("cumulus.config", args[1]);
    setSystemProperty("jruby.home");
    PropertyConfigurator.configure(this); //Log4J configuration
  }
  
  public <T> T loadRubyObject(String rObjectFile, Class<T> rInterface)
  {
    return loadRubyObject(rObjectFile, rInterface, new HashMap<String,String>());
  }
  
  public <T> T loadRubyObject(String rObjectFile, Class<T> rInterface, HashMap<String,String> specialParams)
  {
    assertProperty("cumulus.home");
    System.out.println("Creating Object : " + rObjectFile + " ... ");
    System.out.flush();
    ScriptingContainer container = new ScriptingContainer();
    container.getProvider().getRubyInstanceConfig().setCompatVersion(CompatVersion.RUBY1_9);
    
    Object receiver;
    
    receiver = container.runScriptlet(PathType.CLASSPATH, "util/jrb_compat.rb");
    receiver = container.runScriptlet(PathType.CLASSPATH, "config/config.rb");
    RubyConfigIface rConfig = container.getInstance(receiver, RubyConfigIface.class);

    rConfig.parse_opt("config_file", getProperty("cumulus.config"));
    rConfig.parse_opt("cumulus.home", getProperty("cumulus.home"));
    rConfig.parse_opt("compiler.home", getProperty("compiler.home"));
    for(Map.Entry<String,String> parameter : parameters.entrySet()){
      rConfig.parse_opt(parameter.getKey(), parameter.getValue());
    }
    for(Map.Entry<String,String> parameter : specialParams.entrySet()){
      rConfig.parse_opt(parameter.getKey(), parameter.getValue());
    }
    rConfig.load(getProperty("cumulus.config"));
    
    receiver = container.runScriptlet(PathType.CLASSPATH, "util/cloud_logger.rb");

    receiver = container.runScriptlet(PathType.CLASSPATH, rObjectFile);
    T handler = container.getInstance(receiver, rInterface);
    return handler;
  }
  
  protected class CumulusOption {
    public final String longForm;
    public final String shortForm;
    public final String name;
    public final boolean requiresParameter;
    
    public CumulusOption(String longForm, String shortForm, boolean requiresParameter)
    {
      this.name = longForm;
      this.longForm = "--" + longForm;
      if(shortForm != null){
        this.shortForm = "-" + shortForm;
      } else {
        this.shortForm = null;
      }
      this.requiresParameter = requiresParameter;
    }
    
    public boolean match(String opt)
    {
      return  opt.equals(this.longForm) || 
              ((shortForm != null) && (opt.equals(shortForm)));
    }
  }
  
  public static boolean isOption(String opt)
  {
    return opt.charAt(0) == '-';
  }
}