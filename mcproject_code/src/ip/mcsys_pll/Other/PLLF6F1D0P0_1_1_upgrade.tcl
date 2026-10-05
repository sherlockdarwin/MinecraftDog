proc report_ip_status { current_ip_version original_ip_version upgrade_result current_part recommended_part } {
    
    set $current_ip_version [string trim $current_ip_version]
    set $current_part   [string trim $current_part]
    set $recommended_part   [string trim $recommended_part]
    set $original_ip_version    [string trim $original_ip_version]
    set $upgrade_result     [string trim $upgrade_result]

    if {$current_part != $recommended_part } {
        set IP_Status 3
        set Recommendation 1
        set Lock 1
        set Upgradable 0
        #puts "current_part is different from recommended_part"
        return [list $IP_Status $Recommendation $Lock $Upgradable ]
    }

    set recommend_version "1.1.0"
    set IP_comparibiliy_table [list "1.1.0" "1.0.0"]
    #puts "IP_comparibiliy_table is $IP_comparibiliy_table"
    set comparibiliy_result [lsearch -exact $IP_comparibiliy_table $current_ip_version]
    set recommend_version_list [split $recommend_version "."]
    set current_version_list [split $current_ip_version "."]

    if {$comparibiliy_result == -1} {
        set IP_Status 3
        set Recommendation 1
        set Lock 1
        set Upgradable 0
        #puts "version is no include"
        return [list $IP_Status $Recommendation $Lock $Upgradable]      
    } elseif {[lindex $recommend_version_list 0] != [lindex $current_version_list 0]} {
        set IP_Status 0
        set Recommendation 0
        set Lock 1
        set Upgradable 1
        return [list $IP_Status $Recommendation $Lock $Upgradable]              
    } elseif {[lindex $recommend_version_list 1] != [lindex $current_version_list 1]} {
        set IP_Status 1 
        set Recommendation 0
        set Lock 1
        set Upgradable 1
        return [list $IP_Status $Recommendation $Lock $Upgradable]
    } elseif {[lindex $recommend_version_list 2] != [lindex $current_version_list 2]} {
        set IP_Status 2
        set Recommendation 0
        set Lock 1
        set Upgradable 1
        return [list $IP_Status $Recommendation $Lock $Upgradable]            
    } elseif {$current_ip_version == $recommend_version} {
        set IP_Status 4
        set Recommendation 2
        set Lock 0
        set Upgradable 0
        return [list $IP_Status $Recommendation $Lock $Upgradable]             
    } else {
        set IP_Status 3
        set Recommendation 1
        set Lock 1
        set Upgradable 0            
        return [list $IP_Status $Recommendation $Lock $Upgradable]
    }
}

proc upgrade_ip	{ param_txt_path port_txt_path current_ip_version } {

    if {([file exists $param_txt_path] == 0) || ([file exists $port_txt_path] == 0)} {
        #puts "param_txt_path or port_txt_path is not exists, upgrade exit"
        return 0
    } else {
        #puts "param_txt_path and port_txt_path is exists !!!!"
        set param_get [open "$param_txt_path" r ] 
        set param_set [open "$param_txt_path" r ] 
    }
    set a_content ""
#--get correct Bandwith setting
    while {[gets $param_get line] >= 0} {
        set input_file_line [split $line ":"]
        set input_file_line_index0 [lindex $input_file_line 0]
        set input_file_line_index1 [lindex $input_file_line 1]
        set input_file_line_index0 [string trim $input_file_line_index0]
        set input_file_line_index1 [string trim $input_file_line_index1]

        if {$input_file_line_index0 == "VREF_FREQ_DISP"} {
            set vref_ $input_file_line_index1
            if {$vref_ < 40} {
                #puts "vref_ is $vref_"
                set BD_list {Low}
            } else {
                set BD_list {High}
            }
        }
    }
    close $param_get
#--config correct Bandwith setting
    while {[gets $param_set line ] >= 0} {
        #puts "line is $line \n"
        set input_file_line [split $line ":"]
        set input_file_line_index0 [lindex $input_file_line 0]
        #set input_file_line_index1 [lindex $input_file_line 1]
        #set input_file_line_index2 [lindex $input_file_line 2]
        #set input_file_line_index3 [lindex $input_file_line 3]
        set input_file_line_index4 [lindex $input_file_line 4]
        #set input_file_line_index5 [lindex $input_file_line 5]

        set input_file_line_index0 [string trim $input_file_line_index0]
        #set input_file_line_index1 [string trim $input_file_line_index1]
        #set input_file_line_index2 [string trim $input_file_line_index2]
        #set input_file_line_index3 [string trim $input_file_line_index3]
        set input_file_line_index4 [string trim $input_file_line_index4]
        #set input_file_line_index5 [string trim $input_file_line_index5]

    #
        if {($input_file_line_index4 == "High;;Low") && ($input_file_line_index0 == "BandWidth_setting_DISP")} {
            set line "BandWidth_setting_DISP : $BD_list : U : En : $BD_list :  : "
            puts "found parameter BandWidth_setting_DISP"
        }

        append a_content "$line \n" 
    }
    close $param_set
    set new_handle [open "$param_txt_path" w]
        puts -nonewline $new_handle $a_content
        close $new_handle

        return 1
}

